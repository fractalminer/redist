-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )

local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local set_hash = assert( ru.set_hash )
local set_blob = assert( farm.set_blob )

local info = assert( logger.info )

local socket_select = assert( socket.select )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function post_task( cxn, hash, params )
  assert( hash )
  assert( params )
  local key = format( 'farm:compile:cpp:task:%s:input', hash )
  set_hash( cxn, key, {
    os=assert( params.os ),
    compiler_type=assert( params.compiler_type ),
    compiler_version=assert( params.compiler_version ),
    compiler_flags=assert( params.compiler_flags ),
    input=assert( params.input ),
    description=assert( params.description ),
  }, config.builder.EXPIRE_REMOTE_TASK )
end

local function queue_task( cxn, hash )
  assert( hash )
  local key = 'farm:compile:cpp:queue'
  -- Push on the right, then the worker pops from the left to
  -- create a FIFO (queue).
  cxn:rpush( key, hash )
end

local function output_of( cxn, hash )
  assert( cxn )
  assert( hash )
  local key = format( 'farm:compile:cpp:task:%s:output', hash )
  if not cxn:exists( key ) then return end
  local output = assert( cxn:hgetall( key ) )
  assert( type( output ) == 'table' )
  return output
end

local function delete_output( cxn, hash )
  assert( cxn )
  assert( hash )
  local key = format( 'farm:compile:cpp:task:%s:output', hash )
  if not cxn:exists( key ) then return end
  assert( cxn:del( key ) )
end

local function find( cxn, hash )
  local key = format( 'farm:compile:cpp:task:%s:input', hash )
  return cxn:hgetall( key )
end

local function set_result( cxn, hash, result )
  local out_key =
      format( 'farm:compile:cpp:task:%s:output', hash )
  local function to_blob( content )
    return set_blob( cxn, content )
  end
  local output = nil
  if result.output and #result.output > 0 then
    output = to_blob( result.output )
  end
  set_hash( cxn, out_key, {
    status=assert( result.status ),
    output=output,
    stdout=to_blob( result.stdout ),
    stderr=to_blob( result.stderr ),
    time_micros=assert( result.time_micros ),
  } )
end

local function publish_event( cxn, task_hash, event )
  assert( task_hash )
  assert( event )
  local key = format( 'farm:compile:cpp:events' )
  event = format( '%s:%s', task_hash, event )
  cxn:publish( key, event )
end

local function queue_and_wait( cxn, task_hash, fn )
  assert( task_hash )
  fn = fn or function() end

  local pubsub_cxn<close> = assert( ru.connect() )
  local sock = assert( pubsub_cxn.network.socket )
  local messages = pubsub_cxn:pubsub{
    subscribe='farm:compile:cpp:events',
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
  queue_task=queue_task,
  find=find,
  set_result=set_result,
  publish_event=publish_event,
  output_of=output_of,
  delete_output=delete_output,
  queue_and_wait=queue_and_wait,
}
