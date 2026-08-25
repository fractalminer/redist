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
local insert = assert( table.insert )
local sort = assert( table.sort )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

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
    local _, _, node, pid = key:tsplit( ':' )
    state.nodes[node] = state.nodes[node] or {}
    state.nodes[node].worker_count =
        state.nodes[node].worker_count or 0
    state.nodes[node].active_worker_count =
        state.nodes[node].active_worker_count or 0
    state.nodes[node].workers = state.nodes[node].workers or {}
    local tbl = cxn:hgetall( key )
    local ip, from_port = assert( tbl.from ):tsplit( ':' )
    state.nodes[node].host = ip
    local worker = {
      pid=tonumber( pid ),
      task=assert( tbl.task ),
      listen=assert( tbl.listen ),
      status=assert( tbl.status ),
      from_port=assert( from_port ),
    }
    if worker.status ~= 'idle' then
      state.nodes[node].active_worker_count =
          state.nodes[node].active_worker_count + 1
      total_active_worker_count = total_active_worker_count + 1
    end
    total_worker_count = total_worker_count + 1
    state.nodes[node].worker_count =
        state.nodes[node].worker_count + 1
    insert( state.nodes[node].workers, worker )
  end
  state.worker_count = total_worker_count
  state.active_worker_count = total_active_worker_count
  state.core_count = 1 -- TODO
  state.active_core_count = 0 -- TODO
  for _, node in pairs( state.nodes ) do
    node.core_count = 1 -- TODO
    node.active_core_count = 0 -- TODO
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
