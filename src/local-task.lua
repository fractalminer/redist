-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local keys = require( 'keys' )
local network = require( 'network' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )

local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local machine_label = assert( network.machine_label )
local set_blob_from_string = assert( farm.set_blob_from_string )
local set_blob_from_file = assert( farm.set_blob_from_file )
local set_hash = assert( ru.set_hash )

local info = assert( logger.info )

local socket_select = assert( socket.select )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function post_task( cxn, hash, params )
  assert( hash )
  assert( params )
  assert( params.command )
  assert( params.description )
  if params.cwd then assert( #params.cwd > 0 ) end
  local key = keys.task_input( hash )
  set_hash( cxn, key, {
    command=params.command,
    cwd=params.cwd,
    description=params.description,
  }, config.builder.EXPIRE_LOCAL_TASK )
end

local function queue_task( cxn, hash )
  assert( hash )
  local key = keys.local_queue( machine_label() )
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

local function set_result( cxn, hash, task_output )
  local out_key = keys.task_output( hash )
  local function to_blob( content )
    return set_blob_from_string( cxn, content )
  end
  local stderr = task_output.stderr:trim()
  set_hash( cxn, out_key, {
    status=assert( task_output.status ),
    stdout=to_blob( task_output.stdout ),
    stderr=to_blob( stderr ),
    has_stderr=(#stderr > 0),
    time_micros=assert( task_output.time_micros ),
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

  -- NOTE: unlike with the remote task, we don't first check if
  -- the task output is already cached because for our pre-
  -- processor tasks the input task hash does not include the
  -- hash of all the input files (that would be impractical), so
  -- we need to unconditionally rerun the local task. This is ok
  -- because if the resulting preprocessed file has been seen be-
  -- fore precisely then ccache will have detected that and in-
  -- tercepted us; we should only be here if either we have no
  -- ccache hit or we have genuinely new inputs.
  delete_output( cxn, task_hash )

  local output

  queue_task( cxn, task_hash )

  local target = format( '%s:finished', task_hash )
  while not output do
    info( 'waiting for local task...' )
    fn()
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
