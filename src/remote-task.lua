-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local keys = require( 'keys' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )

local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local set_hash = assert( ru.set_hash )
local set_blob_from_string = assert( farm.set_blob_from_string )

local info = assert( logger.info )

local socket_select = assert( socket.select )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function post_task( cxn, hash, params )
  assert( hash )
  assert( params )
  assert( type( params ) == 'table' )
  assert( params.os )
  local key = keys.task_input( hash )
  set_hash( cxn, key, params, config.builder.EXPIRE_REMOTE_TASK )
end

local function queue_task( cxn, hash )
  assert( hash )
  local key = keys.remote_distributor_queue()
  -- Push on the right, then the worker pops from the left to
  -- create a FIFO (queue).
  cxn:rpush( key, hash )
end

local function output_of( cxn, hash )
  assert( cxn )
  assert( hash )
  local key = keys.task_output( hash )
  if not cxn:exists( key ) then return end
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

local function set_result( cxn, _, _, hash, result )
  local out_key = keys.task_output( hash )
  local function blobify( content )
    local blob = set_blob_from_string( cxn, content )
    assert( type( blob ) == 'table' )
    assert( type( blob.hash ) == 'string' )
    return blob.hash
  end
  local output = nil
  if result.output and #result.output > 0 then
    output = blobify( result.output )
  end
  local stderr = result.stderr:trim()
  set_hash( cxn, out_key, {
    status=assert( result.status ),
    output=output,
    stdout=blobify( result.stdout ),
    stderr=blobify( stderr ),
    has_stderr=(#stderr > 0),
    time_micros=assert( result.time_micros ),
  } )
end

local function publish_event( cxn, task_hash, event )
  assert( task_hash )
  assert( event )
  local key = keys.task_events()
  event = format( '%s:%s', task_hash, event )
  cxn:publish( key, event )
end

local function queue_and_wait( cxn, task_hash, fn )
  assert( task_hash )
  fn = fn or function() end

  local pubsub_cxn<close> = assert( ru.connect() )
  local sock = assert( pubsub_cxn.network.socket )
  local messages = pubsub_cxn:pubsub{
    subscribe=keys.task_events(),
  }

  local output = output_of( cxn, task_hash )
  if output then return output end

  queue_task( cxn, task_hash )

  local target = format( '%s:finished', task_hash )
  while not output do
    info( 'waiting for remote task...' )
    fn()
    assert( cxn:ping(), 'lost connection (primary)' )
    if socket_select( { sock }, {}, 1 )[sock] then
      local message, abort = messages()
      if not message then break end
      if message.kind == 'message' and
          message.payload:match( target ) then
        abort() --
      end
    end
    output = output_of( cxn, task_hash )
  end
  return output or output_of( cxn, task_hash )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  post_task=post_task,
  find=find,
  set_result=set_result,
  publish_event=publish_event,
  output_of=output_of,
  delete_output=delete_output,
  queue_and_wait=queue_and_wait,
}
