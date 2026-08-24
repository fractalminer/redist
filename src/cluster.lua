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
local tsplit = assert( str.tsplit )

local insert = assert( table.insert )
local sort = assert( table.sort )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function query_cluster_state( cxn )
  assert( cxn )
  local state = {}
  local nodes = {}
  state.nodes = nodes
  local keys = cxn:keys( 'farm:worker:*' )
  sort( keys )
  local total_worker_count = 0
  local total_active_worker_count = 0
  for _, key in ipairs( keys ) do
    local _, _, node, pid = tsplit( key, ':' )
    state.nodes[node] = state.nodes[node] or {}
    state.nodes[node].worker_count =
        state.nodes[node].worker_count or 0
    state.nodes[node].active_count =
        state.nodes[node].active_count or 0
    state.nodes[node].workers = state.nodes[node].workers or {}
    local tbl = cxn:hgetall( key )
    local worker = {
      pid=tonumber( pid ),
      task=assert( tbl.task ),
      listen=assert( tbl.listen ),
      status=assert( tbl.status ),
    }
    total_worker_count = total_worker_count + 1
    if worker.status ~= 'idle' then
      state.nodes[node].active_count =
          state.nodes[node].active_count + 1
      total_active_worker_count = total_active_worker_count + 1
    end
    insert( state.nodes[node].workers, worker )
  end
  state.worker_count = total_worker_count
  state.active_worker_count = total_active_worker_count
  for _, node in pairs( state.nodes ) do
    node.worker_count = #node.workers
  end
  return state
end

local function print_cluster_state()
  local cxn<close> = assert( ru.connect() )
  local state = assert( query_cluster_state( cxn ) )
  print( json.tostring_pretty( state ) )
end

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return {
  query_cluster_state=query_cluster_state,
  print_cluster_state=print_cluster_state,
}
