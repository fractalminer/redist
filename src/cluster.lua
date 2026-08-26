-- Queries cluster/worker state.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local ru = require( 'redis-util' )

local json = require( 'moon.json' )
local str = require( 'moon.str' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local format = assert( string.format )
local insert = assert( table.insert )
local max = assert( math.max )
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
  local keys = cxn:keys( 'farm:worker:*' )
  sort( keys )
  for _, key in ipairs( keys ) do
    if key:match( 'approximate_active' ) then goto continue end
    local _, _, node, pid = key:tsplit( ':' )
    state.nodes[node] = state.nodes[node] or {}
    state.nodes[node].workers = state.nodes[node].workers or {}
    if opts.exclude_workers then goto continue end
    local tbl = cxn:hgetall( key )
    -- This catches races that happen when we flushdb and the key
    -- we're querying disappears before the above hgetall query.
    if not tbl or not tbl.from then goto continue end
    local _, from_port = assert( tbl.from ):tsplit( ':' )
    -- state.nodes[node].host = ip
    local worker = {
      pid=tonumber( pid ),
      task=assert( tbl.task ),
      listen=assert( tbl.listen ),
      status=assert( tbl.status ),
      from_port=assert( from_port ),
    }
    insert( state.nodes[node].workers, worker )
    ::continue::
  end
  state.core_count = 1 -- TODO
  state.active_core_count = 0 -- TODO
  state.preprocess_queue_size = cxn:llen(
                                    'farm:compile:cpp:task:queue' )
  state.compile_queue_size = cxn:llen( 'farm:local:task:queue' )
  state.active_worker_count = 0
  state.local_active_worker_count = 0
  state.worker_count = 0
  for name, node in pairs( state.nodes ) do
    node.core_count = 1 -- TODO
    node.active_core_count = 0 -- TODO
    local function get_count( label )
      local key = format( 'farm:node:%s:count:%s', name, label )
      local n = cxn:get( key )
      n = n or 0
      n = tonumber( n )
      n = max( n, 0 )
      return n
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
