-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local keys = require( 'keys' )
local network = require( 'network' )
local ru = require( 'redis-util' )

local file = require( 'moon.file' )
local logger = require( 'moon.logger' )

local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local create_blob_from_file =
    assert( farm.create_blob_from_file )
local create_delta = assert( farm.create_delta )
local machine_label = assert( network.machine_label )
local set_blob_from_string = assert( farm.set_blob_from_string )
local set_hash = assert( ru.set_hash )
local upload_blob = assert( farm.upload_blob )
local upload_delta = assert( farm.upload_delta )

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
  set_hash( cxn, key, params, config.builder.EXPIRE_LOCAL_TASK )
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

local function register_preprocessed( cxn, lc, task_hash, ii_file )
  assert( cxn )
  assert( lc )
  assert( task_hash )
  assert( ii_file )

  local new_blob = assert( create_blob_from_file( ii_file ) )
  local new_hash = assert( new_blob.hash )

  if not config.worker.SEND_PREPROCESSED_DELTAS then
    upload_blob( cxn, new_blob )
    return { type='blob', hash=new_hash }
  end

  -- TODO: need to improve this.
  local tu_key = task_hash

  local base_hash = lc:preprocessed_get( tu_key )

  local base_in_redis = base_hash and
                            farm.blob_exists( cxn, base_hash )

  if new_hash == base_hash and base_in_redis then
    -- The new preprocessed output is the same as the previous
    -- one and it is both in redis and in the local cache, so we
    -- don't need to do anything.
    return { type='blob', hash=base_hash }
  end

  -- The result has changed from the stored base.

  local base_blob = base_hash and lc:blob_get( base_hash )
  if not base_blob or not base_in_redis then
    -- Store the new blob in the local cache.
    lc:preprocessed_update( tu_key, new_hash )
    lc:blob_set( new_blob )
    -- Upload the new blob to redis.
    upload_blob( cxn, new_blob, { force=true } )
    return { type='blob', hash=new_hash }
  end

  -- The base blob exists in sqlite and is in redis.
  local delta = assert( create_delta( base_blob, new_blob ) )
  -- Do not update the local sqlite cache.
  upload_delta( cxn, delta )

  return { type='delta', hash=assert( delta.manifest.hash ) }
end

local function set_result( cxn, l_cxn, lc, hash, task_output )
  local out_key = keys.task_output( hash )
  local function blobify( content )
    local blob = set_blob_from_string( l_cxn, content )
    assert( type( blob ) == 'table' )
    assert( type( blob.hash ) == 'string' )
    return blob.hash
  end
  local stderr = task_output.stderr:trim()
  local ii_type, ii_hash
  local output_file = assert( task_output.output_file )
  if file.exists( output_file ) then
    local registered = assert( register_preprocessed( cxn, lc,
                                                      hash,
                                                      output_file ) )
    assert( type( registered ) == 'table' )
    ii_type = assert( registered.type )
    ii_hash = assert( registered.hash )
  end
  set_hash( l_cxn, out_key, {
    status=assert( task_output.status ),
    stdout=blobify( task_output.stdout ),
    stderr=blobify( stderr ),
    has_stderr=(#stderr > 0),
    time_micros=assert( task_output.time_micros ),
    ii_type=ii_type,
    ii_hash=ii_hash,
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
