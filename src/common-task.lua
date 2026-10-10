-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local keys = require( 'keys' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function output_of( cxn, hash )
  assert( cxn )
  assert( hash )
  local key = keys.task_output( hash )
  local output = cxn:hgetall( key )
  -- For a key that doesn't exist it will return an empty table.
  -- We can use this to save a separate ping to the server just
  -- to first test if the key exists.
  assert( type( output ) == 'table' )
  if not next( output ) then return end
  assert( output.has_stderr == 'true' or output.has_stderr ==
              'false' )
  output.has_stderr = (output.has_stderr == 'true')
  return output
end

local function delete_output( cxn, hash )
  assert( cxn )
  assert( hash )
  local key = keys.task_output( hash )
  if not cxn:exists( key ) then return end
  assert( cxn:del( key ) )
end

local function find( cxn, hash )
  local key = keys.task_input( hash )
  return cxn:hgetall( key )
end

local function publish_event( cxn, task_hash, event )
  assert( task_hash )
  assert( event )
  local key = keys.task_events()
  event = format( '%s:%s', task_hash, event )
  cxn:publish( key, event )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  find=find,
  publish_event=publish_event,
  output_of=output_of,
  delete_output=delete_output,
}
