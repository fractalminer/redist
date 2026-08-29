-----------------------------------------------------------------
-- Dashboard for build farm control/monitoring.
-----------------------------------------------------------------
local config = require( 'config' )
local ru = require( 'redis-util' )
local farm = require( 'farm' )
local cluster = require( 'cluster' )

local mcleanup = require( 'moon.cleanup' )
local merr = require( 'moon.err' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )
local tbl = require( 'moon.tbl' )

local mc = require( 'minicurses' )
local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local query_cluster_state = assert( cluster.query_cluster_state )
local WorkerCount = assert( farm.WorkerCount )

local catch_control_c = assert( merr.catch_control_c )
local cleanup = assert( mcleanup.cleanup )
local on_ordered_kv = assert( tbl.on_ordered_kv )
local now_seconds = assert( time.now_seconds )
local timeit_micros = assert( time.timeit_micros )

local socket_select = assert( socket.select )

local format = assert( string.format )
local insert = assert( table.insert )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local POLL_TIMEOUT_SECS = .1
local REDIS_UPDATE_INTERVAL_SECS = 1
local REDRAW_INTERVAL_SECS = .01

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

local g_last_update_time = 0
local g_last_redraw_time = 0

local g_status = ''
local g_sub_status = ''

local g_loops = 0
local g_events = 0
local g_redraws = 0
local g_redis_updates = 0

local INPUT_STATE = { node_label=nil, counter_type=nil }

local g_data = {}

-----------------------------------------------------------------
-- Input processors.
-----------------------------------------------------------------
local function find_node( label )
  local node_labels = {}
  on_ordered_kv( g_data.nodes, function( _, o )
    insert( node_labels, o.node_label )
  end )
  local i
  for j, node_label in ipairs( node_labels ) do
    i = i or j
    if node_label == label then i = j end
  end
  return i, node_labels
end

local function node_up( label )
  local i, node_labels = find_node( label )
  if not i then return end
  i = i - 1
  if i < 1 then i = #node_labels end
  return assert( node_labels[i] )
end

local function node_down( label )
  local i, node_labels = find_node( label )
  if not i then return end
  i = i + 1
  if i > #node_labels then i = 1 end
  return assert( node_labels[i] )
end

local function target_label_up()
  if INPUT_STATE.counter_type == 'local' then
    INPUT_STATE.counter_type = 'both'
  else
    INPUT_STATE.counter_type = 'local'
    INPUT_STATE.node_label = node_up( INPUT_STATE.node_label )
  end
end

local function target_label_down()
  if INPUT_STATE.counter_type == 'local' or
      INPUT_STATE.node_label == nil then
    INPUT_STATE.counter_type = 'both'
    INPUT_STATE.node_label = node_down( INPUT_STATE.node_label )
  else
    INPUT_STATE.counter_type = 'local'
  end
end

local function increase_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  -- The node manager will impose this limit itself as well for
  -- extra safety, but for a good UX we will impose it here in
  -- the dashboard UI.
  local max_count = config.node_manager.MAX_WORKERS_PER_TYPE
  local cur_count = worker_count:get()
  if cur_count > max_count then
    worker_count:set( max_count )
  elseif cur_count == max_count then
    return
  else
    worker_count:inc()
  end
end

local function decrease_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  worker_count:dec()
end

local function clear_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  worker_count:set( 0 )
end

local function full_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  -- TODO
  worker_count:set( 16 )
end

-----------------------------------------------------------------
-- Socket helpers.
-----------------------------------------------------------------
local stdin_sock = {
  getfd=function() return 0 end,
  dirty=function() return false end,
}

local function next_event( pubsub_cxn, timeout )
  local redis_sock = assert( pubsub_cxn.network.socket )
  local readable = socket_select( { stdin_sock, redis_sock }, {},
                                  timeout )
  if not readable then return end
  local events = {}
  for _, sock in ipairs( readable ) do
    if sock == stdin_sock then
      -- Should call mc.getkey() to get the key. Note that
      -- calling getch() isn't sufficient because it doesn't
      -- handle the multi-byte keys like arrow keys.
      events.keyboard = true
    elseif sock == redis_sock then
      -- Should call the pub/sub iterator to read the data.
      events.redis = true
    end
  end
  return events
end

-----------------------------------------------------------------
-- Redis Data.
-----------------------------------------------------------------
local function percent( n, d )
  assert( n )
  assert( d )
  if d == 0 then return 0 end
  return n / d
end

local function update_data( cxn, opts )
  assert( cxn )
  opts = opts or {}
  local now = now_seconds()
  if not opts.force then
    if now < g_last_update_time + REDIS_UPDATE_INTERVAL_SECS then
      return
    end
  end
  g_last_update_time = now
  g_redis_updates = g_redis_updates + 1

  local query_time, state = timeit_micros( function()
    return query_cluster_state( cxn, {
      exclude_workers=true, --
    } )
  end )
  assert( state )
  g_data = {}
  g_data.query_time_micros = query_time
  g_data.stats = {}
  local stats = g_data.stats

  g_data.stats.preprocess_queue_size = assert(
                                           state.preprocess_queue_size )
  g_data.stats.compile_queue_size = assert(
                                        state.compile_queue_size )

  stats.cores = assert( state.core_count )
  stats.active_cores = assert( state.active_core_count )
  stats.core_utilization = percent( stats.active_cores,
                                    stats.cores )
  stats.mem = assert( state.mem_total_gb )
  stats.active_mem = assert( state.mem_used_gb )
  stats.mem_utilization = percent( stats.active_mem, stats.mem )
  stats.active_workers = 0
  stats.local_active_workers = assert(
                                   state.local_active_worker_count )
  stats.total_workers = assert( state.worker_count )
  stats.local_workers = assert( state.local_worker_count )
  stats.active_workers = assert( state.active_worker_count )
  g_data.nodes = {}
  local nodes = g_data.nodes
  on_ordered_kv( state.nodes, function( k, v )
    local name, machine_id = k:tsplit( '-' )
    local node = {}
    node.id = machine_id
    node.name = name
    node.node_label = k
    node.from_host = 'unknown' -- assert( v.host )
    node.cores = assert( v.core_count )
    node.active_cores = assert( v.active_core_count )
    node.core_utilization = percent( node.active_cores,
                                     node.cores )
    node.mem = assert( v.mem_total_gb )
    node.active_mem = assert( v.mem_used_gb )
    node.mem_utilization = percent( node.active_mem, node.mem )
    node.active_workers = assert( v.active_worker_count )
    node.total_workers = assert( v.worker_count )
    node.local_workers = assert( v.local_worker_count )
    node.remote_workers = node.total_workers - node.local_workers
    node.local_active_workers = assert(
                                    v.local_active_worker_count )
    node.worker_utilization = percent( node.active_workers,
                                       node.total_workers )
    node.remote_active_workers =
        node.active_workers - node.local_active_workers
    node.remote_worker_utilization = percent(
                                         node.remote_active_workers,
                                         node.remote_workers )
    node.local_worker_utilization = percent(
                                        node.local_active_workers,
                                        node.local_workers )
    node.target_count = assert( v.target_count )
    insert( nodes, node )
  end )
  stats.worker_utilization = percent( stats.active_workers,
                                      stats.total_workers )
  stats.remote_active_workers = stats.active_workers -
                                    stats.local_active_workers
  stats.remote_workers = stats.total_workers -
                             stats.local_workers
  stats.remote_worker_utilization = percent(
                                        stats.remote_active_workers,
                                        stats.remote_workers )
  stats.local_worker_utilization = percent(
                                       stats.local_active_workers,
                                       stats.local_workers )
end

-----------------------------------------------------------------
-- Curses helpers.
-----------------------------------------------------------------
local function move( point )
  mc.move( assert( point.y ), assert( point.x ) )
end

local function text( ... )
  local txt
  if #{ ... } == 1 then
    txt = ...
  else
    txt = format( ... )
  end
  mc.addstr( txt )
  mc.clrtoeol()
end

local function text_center( y, ... )
  local txt
  if #{ ... } == 1 then
    txt = ...
  else
    txt = format( ... )
  end
  local len = #txt
  local left = mc.COLS // 2 - len // 2
  move{ x=left, y=y }
  mc.addstr( txt )
  mc.clrtoeol()
end

-----------------------------------------------------------------
-- Rendering.
-----------------------------------------------------------------
local function progress_bar( len, pc )
  len = math.max( len, 2 )
  local n_bar = math.floor( len * pc )
  local n_spaces = math.max( len - n_bar, 0 )
  local bar = string.rep( '#', n_bar )
  local spaces = string.rep( '-', n_spaces )
  return format( '[%s%s]', bar, spaces )
end

local function redraw()
  local now = now_seconds()
  if now < g_last_redraw_time + REDRAW_INTERVAL_SECS then return end
  g_last_redraw_time = now
  g_redraws = g_redraws + 1
  if g_redraws % 20 == 0 then mc.clear() end
  -- mc.clear()

  local y = 0
  local old_x = 2
  local function advance( x )
    x = x or old_x
    old_x = x
    y = y + 1
    move{ x=x, y=y }
  end
  local function center( ... ) text_center( y, ... ) end
  local function textln( ... )
    text( ... )
    advance()
  end

  local box_start = nil
  local function start_box( title )
    box_start = y
    advance()
    center( title )
    advance()
  end
  local function finish_box()
    local box_end = y
    mc.mvbox( box_start, 0, box_end, mc.COLS - 1 )
    -- advance()
    move{ x=1, y=y }
  end

  local has_nodes = #g_data.nodes > 0

  start_box( 'ReDist Build Farm Dashboard' )
  finish_box()

  -- Cluster.
  if has_nodes then
    start_box( 'CLUSTER' )
    advance()
    textln( '%s', progress_bar( mc.COLS - 6,
                                g_data.stats.core_utilization ) )
    center( '(core utilization)' )
    advance()
    advance()
    textln( '%s', progress_bar( mc.COLS - 6, g_data.stats
                                    .remote_worker_utilization ) )
    center( '(r-worker utilization)' )
    advance()
    advance()
    textln( '%s', progress_bar( mc.COLS - 6, g_data.stats
                                    .local_worker_utilization ) )
    center( '(l-worker utilization)' )
    advance()
    advance()
    center( 'core usage: %.1f/%s (%.1f%%)',
            g_data.stats.active_cores, g_data.stats.cores,
            g_data.stats.core_utilization * 100 )
    advance()
    center( 'r-worker usage: %s/%s (%.1f%%)', g_data.stats
                .active_workers -
                g_data.stats.local_active_workers, g_data.stats
                .total_workers - g_data.stats.local_workers,
            g_data.stats.remote_worker_utilization * 100 )
    advance()
    center( 'l-worker usage: %s/%s (%.1f%%)',
            g_data.stats.local_active_workers,
            g_data.stats.local_workers,
            g_data.stats.local_worker_utilization * 100 )
    advance()
    advance()
    finish_box()
  end

  -- Queues.
  start_box( 'QUEUES' )
  advance()
  center( 'preprocess: %s', g_data.stats.preprocess_queue_size )
  advance()
  center( 'compile: %s', g_data.stats.compile_queue_size )
  advance()
  advance()
  finish_box()

  -- Nodes.
  if has_nodes then start_box( 'NODES' ) end
  for _, node in ipairs( g_data.nodes ) do
    advance( 2 )
    textln( 'NODE: %s [%s]', node.name, node.from_host )
    mc.hline( mc.COLS - 4 )

    advance( 4 )
    textln( 'core:   %s',
            progress_bar( mc.COLS - 18, node.core_utilization ) )
    textln( 'mem:    %s',
            progress_bar( mc.COLS - 18, node.mem_utilization ) )
    textln( 'worker: %s', progress_bar( mc.COLS - 18,
                                        node.remote_worker_utilization ) )
    if node.local_workers > 0 then
      textln( 'local:  %s', progress_bar( mc.COLS - 18,
                                          node.local_worker_utilization ) )
    end

    advance( 4 )
    local function counter_widget( counter_type )
      local is_selected = INPUT_STATE.node_label ==
                              node.node_label and
                              INPUT_STATE.counter_type ==
                              counter_type
      local caret = is_selected and '>' or ' '
      return format( '%s %5s target: %d', caret, counter_type,
                     node.target_count[counter_type] )
    end
    local both_widget = counter_widget( 'both' )
    local local_widget = counter_widget( 'local' )
    textln( 'core   usage: %2.1fs/%2s (%3.1f%%)    %s',
            node.active_cores, node.cores,
            node.core_utilization * 100, both_widget )
    textln( 'worker usage: %2s/%2s (%3.1f%%)    %s',
            node.remote_active_workers, node.remote_workers,
            node.remote_worker_utilization * 100, local_widget )
    if node.local_workers > 0 then
      textln( 'local  usage: %2s/%2s (%3.1f%%)',
              node.local_active_workers, node.local_workers,
              node.local_worker_utilization * 100 )
    end
  end
  if has_nodes then
    advance()
    finish_box()
  end

  y = mc.LINES - 8
  advance( 2 )
  textln( 'status:  %s', g_status )
  textln( 'substat: %s', g_sub_status )
  textln( 'updates: %s [%.1fms]', g_redis_updates,
          (g_data.query_time_micros or 0) / 1000 )
  textln( 'redraws: %s', g_redraws )
  textln( 'events:  %s', g_events )
  textln( 'loops:   %s', g_loops )

  move{ x=mc.COLS - 1, y=mc.LINES - 1 }

  mc.refresh()
end

-----------------------------------------------------------------
-- Main loop.
-----------------------------------------------------------------
local function loop( cxn, pubsub_cxn, pubsub_msgs )
  assert( cxn )
  assert( pubsub_cxn )
  assert( pubsub_msgs )
  while true do
    update_data( cxn )
    redraw()
    g_loops = g_loops + 1
    local input = assert( next_event( pubsub_cxn,
                                      POLL_TIMEOUT_SECS ) )
    if input.keyboard then
      local key = mc.getkey()
      if key == 'q' then return true end
      g_status = 'key=' .. key
      g_events = g_events + 1
      if key == 'j' or key == 'DOWN' then
        target_label_down()
      end
      if key == 'k' or key == 'UP' then target_label_up() end
      if key == 'l' or key == 'RIGHT' then
        increase_target_count( cxn )
      end
      if key == 'h' or key == 'LEFT' then
        decrease_target_count( cxn )
      end
      if key == 'x' then clear_target_count( cxn ) end
      if key == 'f' then full_target_count( cxn ) end
      g_sub_status = format( 'node=%s,type=%s',
                             INPUT_STATE.node_label,
                             INPUT_STATE.counter_type )
      update_data( cxn, { force=true } )
    end
    if input.redis then
      pubsub_msgs()
      g_status = 'redis message'
      g_events = g_events + 1
      update_data( cxn, { force=true } )
    end
  end
end

-----------------------------------------------------------------
-- main
-----------------------------------------------------------------
local function main()
  -- Init redis.
  local cxn<close> = assert( ru.connect() )
  local pubsub_cxn<close> = assert( ru.connect() )
  local pubsub_msgs = pubsub_cxn:pubsub{ psubscribe='farm:*' }
  pubsub_msgs()

  -- Init curses.
  mc.initscr()
  local _<close> = cleanup( mc.endwin )

  -- Start main loop.
  return loop( cxn, pubsub_cxn, pubsub_msgs ) and 0 or 1
end

-----------------------------------------------------------------
-- Launch.
-----------------------------------------------------------------
os.exit( catch_control_c( main, function()
  print( 'ctrl-c received, exiting.' )
  return 0
end ) )
