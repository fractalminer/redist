-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local ru = require( 'redis-util' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local set_hash = assert( ru.set_hash )
local set_blob = assert( farm.set_blob )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function create_local_task( cxn, hash, params )
  assert( hash )
  assert( params )
  assert( params.command )
  assert( params.description )
  if params.cwd then assert( #params.cwd > 0 ) end
  local key = format( 'farm:local:task:%s:input', hash )
  set_hash( cxn, key, {
    command=params.command,
    cwd=params.cwd,
    description=params.description,
  }, config.worker.EXPIRE_LOCAL_TASK )
end

local function get_local_task( cxn, hash )
  local key = format( 'farm:local:task:%s:input', hash )
  return cxn:hgetall( key )
end

local function set_local_result( cxn, hash, result )
  local out_key = format( 'farm:local:task:%s:output', hash )
  local function to_blob( content )
    return set_blob( cxn, content )
  end
  set_hash( cxn, out_key, {
    status=assert( result.status ),
    stdout=to_blob( result.stdout ),
    stderr=to_blob( result.stderr ),
  } )
  publish_local_task_event( cxn, hash, 'finished' )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  create_local_task=create_local_task, --
  get_local_task=get_local_task, --
  set_local_result=set_local_result, --
}
