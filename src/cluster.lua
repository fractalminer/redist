-- Queries cluster/worker state.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local ru = require( 'redis-util' )
local farm = require( 'farm' )

local json = require( 'moon.json' )
local str = require( 'moon.str' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local WorkerCount = assert( farm.WorkerCount )

local format = assert( string.format )
local insert = assert( table.insert )
local sort = assert( table.sort )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function query_cluster_state( cxn, opts )
  assert( cxn )
  opts = opts or {}
  opts.exclude_workers = opts.exclude_workers or false
  local state = {}
  local nodes = {}
  state.nodes = nodes
  local keys

  -- First get a list of all nodes just from the node manager ad-
  -- vertisements. This will ensure that nodes with no workers
  -- will be picked up. However, if a node has a worker running
  -- but not a manager running (sometimes done during local test-
  -- ing) the node will still get picked up when iterating
  -- through the workers below.
  keys = cxn:keys( 'farm:node:*:presence:manager' )
  sort( keys )
  for _, key in ipairs( keys ) do
    local _, _, node, _, _ = key:tsplit( ':' )
    nodes[node] = { workers={} }
  end

  -- Now get all workers.
  keys = cxn:keys( 'farm:worker:*' )
  sort( keys )
  for _, key in ipairs( keys ) do
    local _, _, node, pid = key:tsplit( ':' )
    nodes[node] = nodes[node] or {}
    nodes[node].workers = nodes[node].workers or {}
    if opts.exclude_workers then goto continue end
    local tbl = cxn:hgetall( key )
    -- This catches races that happen when we flushdb and the key
    -- we're querying disappears before the above hgetall query.
    if not tbl or not tbl.from then goto continue end
    local _, from_port = assert( tbl.from ):tsplit( ':' )
    local worker = {
      pid=tonumber( pid ),
      task=assert( tbl.task ),
      listen=assert( tbl.listen ),
      status=assert( tbl.status ),
      from_port=assert( from_port ),
    }
    insert( nodes[node].workers, worker )
    ::continue::
  end
  state.preprocess_queue_size = 0
  local local_queues = cxn:keys( 'farm:local:queue:*' )
  for _, local_queue_key in ipairs( local_queues ) do
    state.preprocess_queue_size =
        state.preprocess_queue_size + cxn:llen( local_queue_key )
  end
  state.mem_total_gb = 0
  state.mem_used_gb = 0
  state.mem_percent_used = 0
  state.core_count = 0
  state.active_core_count = 0
  state.cores_percent_used = 0
  state.compile_queue_size = cxn:llen( 'farm:compile:cpp:queue' )
  state.active_worker_count = 0
  state.local_active_worker_count = 0
  state.worker_count = 0
  state.local_worker_count = 0
  local function number( from )
    if not from then return 0 end
    if from == '' then return 0 end
    local num = tonumber( from )
    return assert( num, format( 'invalid number: "%s"', from ) )
  end
  for name, node in pairs( nodes ) do
    local node_stats = cxn:hgetall(
                           format( 'farm:node:%s:stats', name ) )
    node_stats = node_stats or {}
    node_stats.cores_total = node_stats.cores_total or 1
    node_stats.cores_percent_used =
        node_stats.cores_percent_used or 0
    node.mem_total_gb = number( node_stats.mem_total_gb or 0 )
    node.mem_percent_used = number(
                                node_stats.mem_percent_used or 0 )
    node.mem_used_gb = node.mem_total_gb * node.mem_percent_used
    node.core_count = number( node_stats.cores_total )
    node.cores_percent_used = number(
                                  node_stats.cores_percent_used or
                                      0 )
    node.active_core_count = node.core_count *
                                 node.cores_percent_used
    state.core_count = state.core_count + node_stats.cores_total
    state.active_core_count = state.active_core_count +
                                  node.core_count *
                                  node.cores_percent_used
    state.mem_total_gb = state.mem_total_gb + node.mem_total_gb
    state.mem_used_gb = state.mem_used_gb + node.mem_used_gb
    local function get_count( label )
      local key =
          format( 'farm:node:%s:presence:%s', name, label )
      return number( cxn:scard( key ) or 0 )
    end
    node.worker_count = get_count( 'workers_count' )
    node.active_worker_count = get_count( 'workers_active' )
    node.local_worker_count = get_count( 'workers_local' )
    node.local_active_worker_count = get_count(
                                         'workers_active_local' )
    state.active_worker_count = state.active_worker_count +
                                    node.active_worker_count
    state.local_active_worker_count =
        state.local_active_worker_count +
            node.local_active_worker_count
    state.worker_count = state.worker_count + node.worker_count
    state.local_worker_count = state.local_worker_count +
                                   node.local_worker_count

    local remote_target_count =
        WorkerCount( cxn, name, 'remote' ):get()
    local local_target_count =
        WorkerCount( cxn, name, 'local' ):get()
    local both_target_count =
        WorkerCount( cxn, name, 'both' ):get()
    node.target_count = {}
    node.target_count.remote = remote_target_count
    node.target_count['local'] = local_target_count
    node.target_count.both = both_target_count
  end
  if state.core_count > 0 then
    state.cores_percent_used = state.active_core_count /
                                   state.core_count
  end
  if state.mem_used_gb > 0 then
    state.mem_percent_used = state.mem_used_gb /
                                 state.mem_total_gb
  end
  return state
end

local function print_cluster_state( opts )
  local cxn<close> = assert( ru.connect() )
  local state = assert( query_cluster_state( cxn, opts ) )
  print( json.tostring_pretty( state ) )
end

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return {
  query_cluster_state=query_cluster_state,
  print_cluster_state=print_cluster_state,
}
