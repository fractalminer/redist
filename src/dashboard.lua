-----------------------------------------------------------------
-- Dashboard for build farm control/monitoring.
-----------------------------------------------------------------
local config = require( 'config' )
local ru = require( 'redis-util' )
local farm = require( 'farm' )
local cluster = require( 'cluster' )
local terminal = require( 'terminal' )

local mcleanup = require( 'moon.cleanup' )
local merr = require( 'moon.err' )
local mmath = require( 'moon.math' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )
local tbl = require( 'moon.tbl' )

local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local query_cluster_state = assert( cluster.query_cluster_state )
local WorkerCount = assert( farm.WorkerCount )

local catch_control_c = assert( merr.catch_control_c )
local clamp = assert( mmath.clamp )
local cleanup = assert( mcleanup.cleanup )
local now_millis = assert( time.now_millis )
local now_micros = assert( time.now_micros )
local on_ordered_kv = assert( tbl.on_ordered_kv )
local timeit_micros = assert( time.timeit_micros )

local socket_select = assert( socket.select )

local format = assert( string.format )
local insert = assert( table.insert )
local sort = assert( table.sort )
local floor = assert( math.floor )
local min = assert( math.min )
local abs = assert( math.abs )

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

local g_needs_clear = true
local g_compact_view = 0
local g_show_node_mem_histerisis = {}
local g_seen_with_local_workers = {}

local g_node_cpu_smoothed = {}

local g_last_term_size = {}

local function reset_cached_rendering_data()
  g_last_update_time = 0
  g_last_redraw_time = 0

  g_status = ''
  g_sub_status = '(reset)'

  INPUT_STATE = { node_label=nil, counter_type=nil }

  g_needs_clear = true
  g_node_cpu_smoothed = {}
end

-----------------------------------------------------------------
-- CPU utilization smoothing.
-----------------------------------------------------------------
local function advance_cpu( node_label, core_utilization )
  local smoothed = g_node_cpu_smoothed
  smoothed[node_label] = smoothed[node_label] or {
    current=core_utilization, --
    velocity=0.0, --
    last_update_time=now_micros(), --
  }
  local o = smoothed[node_label]

  local now = now_micros()

  local dt = now - assert( o.last_update_time )
  o.last_update_time = now

  dt = dt / 20000

  local delta = core_utilization - o.current
  local force = delta
  local accel = 1.0 * force
  o.velocity = o.velocity + accel * dt
  o.velocity = clamp( o.velocity, -.01, .01 )

  local NOISE_LEVEL = .1
  if abs( o.current - core_utilization ) < NOISE_LEVEL then
    dt = dt / 10
  end
  if abs( o.current - core_utilization ) < NOISE_LEVEL / 3 then
    dt = dt / 3
  end
  if abs( o.current - core_utilization ) < NOISE_LEVEL / 10 then
    dt = dt / 3
  end

  local old_current = o.current

  o.current = o.current + o.velocity * dt

  if old_current < core_utilization and o.current >=
      core_utilization then
    o.current = core_utilization
    o.velocity = 0
  elseif old_current > core_utilization and o.current <=
      core_utilization then
    o.current = core_utilization
    o.velocity = 0
  end

  o.current = clamp( o.current, 0.0, 1.0 )
  return o.current < .05 and 0 or o.current
end

-----------------------------------------------------------------
-- Input processors.
-----------------------------------------------------------------
local function find_node( label )
  for node_label, node in pairs( g_data.nodes ) do
    if node_label == label then return node end
  end
end

local function find_node_index( label )
  local labels = {}
  local i
  for j, node_label in ipairs( g_data.node_ordering ) do
    if g_data.nodes[node_label] then
      insert( labels, node_label )
      i = i or j
      if node_label == label then i = #labels end
    end
  end
  return i, labels
end

local function node_up( label )
  local i, node_labels = find_node_index( label )
  if not i then return end
  assert( node_labels )
  assert( node_labels[i] )
  if not g_data.nodes[node_labels[i]] then return end
  if label then
    -- Not the first time we are moving.
    i = i - 1
    if i < 1 then i = #node_labels end
  end
  return assert( node_labels[i] )
end

local function node_down( label )
  local i, node_labels = find_node_index( label )
  if not i then return end
  assert( node_labels )
  assert( node_labels[i] )
  if not g_data.nodes[node_labels[i]] then return end
  if label then
    -- Not the first time we are moving.
    i = i + 1
    if i > #node_labels then i = 1 end
  end
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

local function max_workers_per_type( node_label, opts )
  assert( node_label )
  opts = opts or {}
  local node = assert( find_node( node_label ) )
  local cap = node.cores or 1
  if opts.allow_overdrive then
    -- This generally produces worse build results and so we
    -- shouldn't normally go above the +2 default limit, however
    -- this could be useful if the build happens to be IO bound
    -- for some reason, e.g. slow redis.
    cap = cap * 2
  else
    cap = cap + 2 -- what ninja does.
  end
  -- The node manager will impose this limit itself as well for
  -- extra safety, but for a good UX we will impose it here in
  -- the dashboard UI.
  cap = min( cap, config.node_manager.MAX_WORKERS_PER_TYPE )
  return cap
end

local function increase_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  local max_count = max_workers_per_type( INPUT_STATE.node_label,
                                          { allow_overdrive=true } )
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

local function clear_all_target_counts( cxn )
  for _, node in pairs( g_data.nodes ) do
    local worker_count = WorkerCount( cxn, node.node_label,
                                      'both' )
    worker_count:set( 0 )
    worker_count = WorkerCount( cxn, node.node_label, 'local' )
    worker_count:set( 0 )
  end
end

local function full_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  local max_count = max_workers_per_type( INPUT_STATE.node_label,
                                          { allow_overdrive=false } )
  worker_count:set( max_count )
end

local function overdrive_target_count( cxn )
  if not INPUT_STATE.node_label then return end
  local worker_count = WorkerCount( cxn, INPUT_STATE.node_label,
                                    INPUT_STATE.counter_type )
  local max_count = max_workers_per_type( INPUT_STATE.node_label,
                                          { allow_overdrive=true } )
  worker_count:set( max_count )
end

local function cycle_compact_view()
  g_compact_view = g_compact_view + 1
  g_compact_view = g_compact_view % 3
  g_needs_clear = true
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
      -- Should call getkey() to get the key. Note that calling
      -- getch() isn't sufficient because it doesn't handle the
      -- multi-byte keys like arrow keys.
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

local function get_node_ordering( nodes, node_rank )
  local all = {}
  for label, _ in pairs( nodes ) do all[label] = true end
  for _, label in ipairs( node_rank ) do all[label] = true end
  local ordered = {}
  for k, _ in pairs( all ) do insert( ordered, k ) end
  sort( ordered )
  local res = {}
  for _, label in ipairs( node_rank ) do
    insert( res, label )
    all[label] = false
  end
  for _, label in ipairs( ordered ) do
    if all[label] then insert( res, label ) end
  end
  assert( #res >= #node_rank )
  return res
end

local function update_data( cxn, opts )
  assert( cxn )
  opts = opts or {}
  local now = now_millis()
  if not opts.force then
    if now < g_last_update_time +
        config.dashboard.REDIS_UPDATE_INTERVAL_MILLIS then
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

  g_data.node_rank = assert( state.node_rank )

  local stats = g_data.stats

  g_data.stats.preprocess_queue_size = assert(
                                           state.preprocess_queue_size )
  g_data.stats.compile_queue_size = assert(
                                        state.compile_queue_size )
  g_data.stats.distributor_queue_size = assert(
                                            state.distributor_queue_size )
  g_data.stats.hosts_queue_size =
      assert( state.hosts_queue_size )

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
  on_ordered_kv( state.nodes, function( node_label, v )
    local name, machine_id = node_label:tsplit( '-' )
    local node = {}
    node.id = machine_id
    node.name = name
    node.node_label = node_label
    node.from_host = assert( v.host.ip, 'node ip disppeared' )
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
    node.local_queue_size = assert( v.local_queue_size )
    node.remote_queue_size = assert( v.remote_queue_size )
    nodes[node_label] = node
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
  g_data.node_ordering = get_node_ordering( g_data.nodes,
                                            g_data.node_rank )
end

-----------------------------------------------------------------
-- Curses helpers.
-----------------------------------------------------------------
local function text( out, ... )
  local txt
  if #{ ... } == 1 then
    txt = ...
  else
    txt = format( ... )
  end
  out:text( txt )
  -- out:clear_to_eol()
  return txt
end

local function textw( out, w, ... )
  local txt
  if #{ ... } == 1 then
    txt = ...
  else
    txt = format( ... )
  end

  local width = utf8.len( txt )
  if width < w then txt = txt .. (' '):rep( w - width ) end

  out:text( txt )
  return txt
end

local function text_center( out, y, ... )
  local txt
  if #{ ... } == 1 then
    txt = ...
  else
    txt = format( ... )
  end
  local len = #txt
  local _, cols = terminal.size()
  local left = floor( cols / 2 - len / 2 )
  out:move_to{ x=left, y=y }
  out:text( txt )
  out:clear_to_eol()
end

function box_T( out, point, width, height, style, t, color )
  assert( t )
  assert( t.t_top ~= nil )
  assert( t.t_bottom ~= nil )

  local c = assert( terminal.box_chars[style],
                    'unknown box style: ' .. tostring( style ) )
  assert( c )

  assert( width >= 2 )
  assert( height >= 2 )

  local inner_width = width - 2

  out:fg( color )

  -- Top.
  local nw = c.tl
  local ne = c.tr
  out:move_to( point ):text( nw ):text( c.h:rep( inner_width ) )
      :text( ne )

  -- Sides.
  for row = 1, height - 4 do
    out:move_to{ x=point.x, y=point.y + row }:text( c.v )
    out:move_to{ x=point.x + width - 1, y=point.y + row }:text(
        c.v )
  end

  -- Last (non-bottom) side row, dimmed.
  local dimmed = color
  if t.t_bottom then
    for row = height - 3, height - 2 do
      if row > 0 then
        dimmed = {
          r=dimmed.r * 2 // 3,
          g=dimmed.g * 2 // 3,
          b=dimmed.b * 2 // 3,
        }
        out:fg( dimmed )
        out:move_to{ x=point.x, y=point.y + row }:text( c.v )
        out:move_to{ x=point.x + width - 1, y=point.y + row }
            :text( c.v )
      end
    end
  else
    for row = height - 3, height - 2 do
      if row > 0 then
        out:move_to{ x=point.x, y=point.y + row }:text( c.v )
        out:move_to{ x=point.x + width - 1, y=point.y + row }
            :text( c.v )
      end
    end
  end

  -- Bottom.
  if not t.t_bottom then
    local sw = c.bl
    local se = c.br
    out:move_to{ x=point.x, y=point.y + height - 1 }:text( sw )
        :text( c.h:rep( inner_width ) ):text( se )
  end

  out:reset()

  return out
end

-----------------------------------------------------------------
-- Rendering.
-----------------------------------------------------------------
local function redraw( out )
  -- Check time for redraw.
  local now = now_millis()
  if now < g_last_redraw_time +
      config.dashboard.REDRAW_INTERVAL_MILLIS then return end
  g_last_redraw_time = now
  g_redraws = g_redraws + 1

  local ROWS, COLS = terminal.size()
  if g_last_term_size.rows ~= ROWS or g_last_term_size.cols ~=
      COLS then
    g_needs_clear = true
    g_last_term_size.rows = ROWS
    g_last_term_size.cols = COLS
  end

  if COLS < 80 then
    out:clear()
    text_center( out, ROWS // 2, 'terminal width' )
    text_center( out, ROWS // 2 + 1, 'too small' )
    out:flush()
    return
  end

  -- If we need to clear then do it.
  if g_needs_clear then
    out:clear()
    g_needs_clear = false
  end
  out:move_to{ x=0, y=0 }

  local function compact() return g_compact_view end

  local TITLE_COLOR = terminal.gruvbox.bright_red
  local LABEL_COLOR = terminal.gruvbox.bright_yellow
  local SUB_TITLE_COLOR = terminal.gruvbox.aqua
  local BOX_COLOR = terminal.gruvbox.yellow
  local STATUS_LINE_COLOR = { r=60, g=82, b=16 }
  local DARK_LABEL = terminal.gruvbox.light4

  local y = 0
  local old_x = 2
  local function move( point )
    local new_x = assert( point.x )
    local new_y = point.y or y
    out:move_to{ x=new_x, y=new_y }
    y = new_y
  end
  local function advance( x )
    x = x or old_x
    old_x = x
    y = y + 1
    move{ x=x, y=y }
  end
  local function center( ... ) text_center( out, y, ... ) end
  local function textln( ... )
    text( out, ... )
    advance()
  end
  local function textwmove( w, ... )
    assert( type( w ) == 'number', type( w ) )
    textw( out, w, ... )
  end
  local function cpu_progress_bar( w, fraction, opts )
    opts = opts or {}
    if fraction <= .05 then
      opts.fg = { r=0x30, g=0x60, b=0x30 }
    elseif fraction <= .1 then
      opts.fg = { r=0x50, g=0x80, b=0x50 }
    elseif fraction <= .2 then
      opts.fg = { r=0x8f, g=0xcf, b=0x9f }
    elseif fraction <= .3 then
      opts.fg = { r=0xa8, g=0xe8, b=0x9f }
    elseif fraction <= .4 then
      opts.fg = { r=0xbf, g=0xcf, b=0x8f }
    elseif fraction <= .5 then
      opts.fg = { r=0xaf, g=0xaf, b=0x68 }
    elseif fraction <= .6 then
      opts.fg = { r=0xaf, g=0x9f, b=0x00 }
    elseif fraction <= .7 then
      opts.fg = { r=0xaf, g=0x7f, b=0x00 }
    elseif fraction <= .8 then
      opts.fg = { r=0xaf, g=0x58, b=0x00 }
    elseif fraction <= .9 then
      opts.fg = { r=0xbf, g=0x40, b=0x00 }
    elseif fraction <= .95 then
      opts.fg = { r=0xcf, g=0x30, b=0x00 }
    else
      opts.fg = { r=0xef, g=0x18, b=0x18 }
    end

    opts.bg = { r=0x30, g=0x30, b=0x30 }
    out:progress( w, fraction, opts )
    advance()
  end
  local function worker_progress_bar( w, fraction, opts )
    opts = opts or {}
    opts.fg = { r=0x30, g=0x40, b=0x70 }
    opts.bg = { r=0x30, g=0x30, b=0x30 }
    out:progress( w, fraction, opts )
    advance()
  end
  local function local_worker_progress_bar( w, fraction, opts )
    opts = opts or {}
    opts.fg = { r=0x40, g=0x52, b=0x7a }
    opts.bg = { r=0x30, g=0x30, b=0x30 }
    out:progress( w, fraction, opts )
    advance()
  end
  local function mem_progress_bar( w, fraction, opts )
    opts = opts or {}
    opts.fg = terminal.gruvbox.blue
    if fraction >= .9 then
      opts.fg = terminal.gruvbox.bright_yellow
    end
    opts.bg = { r=0x30, g=0x30, b=0x30 }
    out:progress( w, fraction, opts )
    advance()
  end

  local box_start = nil
  local function start_box( title )
    box_start = y
    advance()
    out:fg( TITLE_COLOR ):bold()
    center( title )
    out:reset()
    advance()
  end
  local function finish_box( t )
    t = t or { t_top=false, t_bottom=false }
    local box_end = y
    box_T( out, { x=0, y=box_start }, COLS,
           box_end - box_start + 1, 'rounded', t, BOX_COLOR )
    move{ x=1, y=y }
  end

  local has_nodes = next( g_data.nodes ) ~= nil

  start_box( 'ReDist Build Farm Dashboard' )
  finish_box{ t_top=false, t_bottom=true }

  -- Cluster.
  if has_nodes then
    start_box( 'CLUSTER' )
    advance()
    move{ x=3 }
    local smoothed_cpu = advance_cpu( 'global', g_data.stats
                                          .core_utilization )
    cpu_progress_bar( COLS - 6, smoothed_cpu )
    out:fg( terminal.gruvbox.blue )
    center( '(core utilization)' )
    out:reset()
    advance()
    advance()
    move{ x=3 }
    worker_progress_bar( COLS - 6,
                         g_data.stats.remote_worker_utilization )
    out:fg( terminal.gruvbox.blue )
    center( '(r-worker utilization)' )
    out:reset()
    advance()
    advance()
    move{ x=3 }
    worker_progress_bar( COLS - 6,
                         g_data.stats.local_worker_utilization )
    out:fg( terminal.gruvbox.blue )
    center( '(l-worker utilization)' )
    out:reset()
    advance()
    advance()
    out:clear_line()
    move{ x=COLS // 2 - 8 }
    out:fg( DARK_LABEL )
    text( out, 'cores: ' )
    out:reset()
    textwmove( 3, '%3d', floor( g_data.stats.active_cores ) )
    textwmove( 5, '/%s', g_data.stats.cores )
    text( out, ' (%.1f%%)', g_data.stats.core_utilization * 100 )
    advance()
    out:clear_line()
    move{ x=COLS // 2 - 12 }
    out:fg( DARK_LABEL )
    text( out, 'r-workers: ' )
    out:reset()
    textwmove( 3, '%3s', g_data.stats.active_workers -
                   g_data.stats.local_active_workers )
    textwmove( 5, '/%s', g_data.stats.total_workers -
                   g_data.stats.local_workers )
    text( out, ' (%.1f%%)',
          g_data.stats.remote_worker_utilization * 100 )
    advance()
    out:clear_line()
    move{ x=COLS // 2 - 12 }
    out:fg( DARK_LABEL )
    text( out, 'l-workers: ' )
    out:reset()
    out:reset()
    textwmove( 3, '%3s', g_data.stats.local_active_workers )
    textwmove( 5, '/%s', g_data.stats.local_workers )
    text( out, ' (%.1f%%)',
          g_data.stats.local_worker_utilization * 100 )
    advance()
    advance()
    finish_box{ t_top=true, t_bottom=true }
  end

  -- Queues.
  start_box( 'QUEUES' )
  advance()
  move{ x=COLS // 2 - 31 }
  out:fg( DARK_LABEL )
  text( out, 'preprocess: ' )
  out:reset()
  textwmove( 6, g_data.stats.preprocess_queue_size )
  out:fg( DARK_LABEL )
  text( out, 'distributor: ' )
  out:reset()
  textwmove( 6, g_data.stats.distributor_queue_size )
  out:fg( DARK_LABEL )
  text( out, 'compile: ' )
  out:reset()
  textwmove( 6, g_data.stats.compile_queue_size )
  out:fg( DARK_LABEL )
  text( out, 'hosts: ' )
  out:reset()
  textwmove( 6, g_data.stats.hosts_queue_size )
  advance()
  advance()
  if has_nodes then
    finish_box{ t_top=true, t_bottom=true }
  else
    finish_box{ t_top=true, t_bottom=false }
  end

  if false then
    advance()
    advance()
    textwmove( 5, '0.05' );
    cpu_progress_bar( COLS - 18, 0.05 )
    textwmove( 5, '0.10' );
    cpu_progress_bar( COLS - 18, 0.10 )
    textwmove( 5, '0.20' );
    cpu_progress_bar( COLS - 18, 0.20 )
    textwmove( 5, '0.30' );
    cpu_progress_bar( COLS - 18, 0.30 )
    textwmove( 5, '0.40' );
    cpu_progress_bar( COLS - 18, 0.40 )
    textwmove( 5, '0.50' );
    cpu_progress_bar( COLS - 18, 0.50 )
    textwmove( 5, '0.60' );
    cpu_progress_bar( COLS - 18, 0.60 )
    textwmove( 5, '0.70' );
    cpu_progress_bar( COLS - 18, 0.70 )
    textwmove( 5, '0.80' );
    cpu_progress_bar( COLS - 18, 0.80 )
    textwmove( 5, '0.90' );
    cpu_progress_bar( COLS - 18, 0.90 )
    textwmove( 5, '0.95' );
    cpu_progress_bar( COLS - 18, 0.95 )
    textwmove( 5, '1.00' );
    cpu_progress_bar( COLS - 18, 1.00 )
    out:flush()
    return
  end

  -- Nodes.
  if has_nodes then start_box( ' NODES' ) end
  for _, node_label in ipairs( g_data.node_ordering ) do
    -- This can happen if there are nodes in the ranking in redis
    -- but which are not online now.
    if not g_data.nodes[node_label] then goto continue end
    local node = assert( g_data.nodes[node_label] )
    advance( 3 )
    out:fg( SUB_TITLE_COLOR )
    out:hline( { x=3, y=y }, COLS - 5 )
    out:hline( { x=2, y=y }, 1, terminal.box_chars.rounded.tl )
    out:hline( { x=COLS - 3, y=y }, 1,
               terminal.box_chars.rounded.tr )
    out:reset()
    advance( 4 )
    out:fg( SUB_TITLE_COLOR )
    out:text( 'NODE' )
    out:reset()
    text( out, ': %s', node.name )
    out:fg{ r=0x70, g=0x70, b=0x70 }
    text( out, ' [%s]', node.from_host )
    out:reset()
    advance( 3 )

    local smoothed_cpu = advance_cpu( node_label,
                                      node.core_utilization )
    advance( 4 )
    out:fg( LABEL_COLOR )
    text( out, 'cpu:    ' )
    out:reset()
    cpu_progress_bar( COLS - 16, smoothed_cpu )
    if compact() < 2 then
      move{ x=4 }
      out:fg( LABEL_COLOR )
      text( out, 'worker: ' )
      out:reset()
      worker_progress_bar( COLS - 16,
                           node.remote_worker_utilization )
      move{ x=4 }
      if node.local_workers > 0 then
        out:fg( LABEL_COLOR )
        text( out, 'local:  ' )
        out:reset()
        local_worker_progress_bar( COLS - 16,
                                   node.local_worker_utilization )
        move{ x=4 }
      end
    end
    -- Most of the time we don't care about memory... we only
    -- care about it if it goes too high.
    if g_show_node_mem_histerisis[node.name] == nil then
      g_show_node_mem_histerisis[node.name] = false
    end
    if compact() < 1 then
      if not g_show_node_mem_histerisis[node.name] and
          node.mem_utilization > .8 then
        g_show_node_mem_histerisis[node.name] = true
        g_needs_clear = true
      elseif g_show_node_mem_histerisis[node.name] and
          node.mem_utilization < .6 then
        g_show_node_mem_histerisis[node.name] = false
        g_needs_clear = true
      end
      if g_show_node_mem_histerisis[node.name] then
        move{ x=4 }
        out:fg( LABEL_COLOR )
        if node.mem_utilization > .8 then
          out:bold()
          text( out, 'mem(!!):' )
          out:reset()
        else
          text( out, 'mem:    ' )
        end
        mem_progress_bar( COLS - 16, node.mem_utilization )
        move{ x=4 }
      end
    end

    local function counter_widget( counter_type )
      local is_selected = INPUT_STATE.node_label ==
                              node.node_label and
                              INPUT_STATE.counter_type ==
                              counter_type
      local caret = is_selected and terminal.symbol.circle or ' '
      local value = node.target_count[counter_type]
      return is_selected, caret, counter_type, value
    end
    local function text_widget(w, is_selected, caret,
                               counter_type, value )
      if is_selected then
        out:fg( terminal.gruvbox.yellow ):bg(
            terminal.gruvbox.dark0 )
        out:text( terminal.symbol.left_round )
        out:bg( terminal.gruvbox.yellow ):fg(
            terminal.gruvbox.dark0 )
        local txt = format( '%s %5s target: %2d', caret,
                            counter_type,
                            node.target_count[counter_type] )
        out:bold()
        textwmove( w, txt )
        out:reset()
      else
        out:text( ' ' )
        out:fg( DARK_LABEL ):text(
            format( '  %5s target: ', counter_type ) )
        out:reset()
        out:text( format( '%2d', value ) )
      end

      if is_selected then
        out:fg( terminal.gruvbox.yellow ):bg(
            terminal.gruvbox.dark0 )
        out:text( terminal.symbol.right_round )
        out:reset()
      else
        out:text( ' ' )
      end
    end
    if compact() < 1 then
      advance()
      out:fg( DARK_LABEL )
      text( out, 'core   usage: ' )
      out:reset()
      textwmove( 20, '%.1fs/%s (%3.1f%%)', node.active_cores,
                 node.cores, node.core_utilization * 100 )
      text_widget( 18, counter_widget( 'both' ) )
      textwmove( 3, '' )
      out:fg( DARK_LABEL )
      textwmove( 13, ' host queue: ' )
      out:reset()
      textwmove( 4, '%d', node.remote_queue_size )

      advance()
      out:fg( DARK_LABEL )
      text( out, 'worker usage: ' )
      out:reset()
      textwmove( 20, '%s/%s (%3.1f%%)',
                 node.remote_active_workers, node.remote_workers,
                 node.remote_worker_utilization * 100 )
      text_widget( 18, counter_widget( 'local' ) )
      textwmove( 3, '' )
      out:fg( DARK_LABEL )
      textwmove( 13, 'local queue: ' )
      out:reset()
      textwmove( 4, '%d', node.local_queue_size )

      advance()
      if node.local_workers > 0 then
        if not g_seen_with_local_workers[node_label] then
          g_seen_with_local_workers[node_label] = true
          g_needs_clear = true
        end
        out:fg( DARK_LABEL )
        text( out, 'local  usage: ' )
        out:reset()
        textwmove( 17, '%s/%s (%3.1f%%)',
                   node.local_active_workers, node.local_workers,
                   node.local_worker_utilization * 100 )
        advance()
      else
        if g_seen_with_local_workers[node_label] then
          g_seen_with_local_workers[node_label] = false
          g_needs_clear = true
        end
      end
    end
    ::continue::
  end
  if has_nodes then
    advance()
    finish_box{ t_top=true, t_bottom=false }
  end

  local function make_status_line()
    out:bg( STATUS_LINE_COLOR )
    out:clear_line()
  end

  y = ROWS - 5
  advance( 2 )
  out:clear_line()
  textln( 'status:  %s', g_status )
  out:clear_line()
  textln( 'substat: %s', g_sub_status )
  out:clear_line()
  textln( 'dimensions: rows=%d, columns=%d | view=%d', ROWS,
          COLS, g_compact_view )
  make_status_line()
  textwmove( 25, 'updates: %s [%.1fms]', g_redis_updates,
             (g_data.query_time_micros or 0) / 1000 )
  textwmove( 16, 'redraws: %s', g_redraws )
  textwmove( 16, 'events: %s', g_events )
  textwmove( 16, 'loops: %s', g_loops )
  out:reset()

  move{ x=COLS - 1, y=ROWS - 1 }

  out:flush()
end

-----------------------------------------------------------------
-- Main loop.
-----------------------------------------------------------------
local function loop( cxn, pubsub_cxn, pubsub_msgs )
  assert( cxn )
  assert( pubsub_cxn )
  assert( pubsub_msgs )
  local out = terminal.buffer()
  while true do
    update_data( cxn )
    redraw( out )
    g_loops = g_loops + 1
    local input = assert(
                      next_event( pubsub_cxn, config.dashboard
                                      .POLL_TIMEOUT_SECS ) )
    if input.keyboard then
      assert( terminal.read_input() )
      while terminal.has_input() do
        local key = terminal.getkey()
        if not key then break end
        if key == 'q' then return true end
        g_status = 'key=' .. key
        g_events = g_events + 1
        if key == 'j' or key == 'DOWN' then
          target_label_down()
        end
        if key == 'k' or key == 'UP' then
          target_label_up()
        end
        if key == 'l' or key == 'RIGHT' then
          increase_target_count( cxn )
        end
        if key == 'h' or key == 'LEFT' then
          decrease_target_count( cxn )
        end
        if key == 'x' then clear_target_count( cxn ) end
        if key == 'X' then clear_all_target_counts( cxn ) end
        if key == 'f' then full_target_count( cxn ) end
        if key == 'F' then overdrive_target_count( cxn ) end
        if key == 'c' then cycle_compact_view() end
        g_sub_status = format( 'node=%s,type=%s',
                               INPUT_STATE.node_label,
                               INPUT_STATE.counter_type )
        if key == 'r' then reset_cached_rendering_data() end
        update_data( cxn, { force=true } )
        g_last_redraw_time = 0 -- force redraw.
      end
    end
    if input.redis then
      pubsub_msgs()
      g_status = 'redis message'
      g_events = g_events + 1
      update_data( cxn, { force=true } )
      g_last_redraw_time = 0 -- force redraw.
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

  -- Init rendering.
  terminal.enter()
  local _<close> = cleanup( terminal.leave )

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
