-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local compression = require( 'compression' )
local config = require( 'config' )
local hasher = assert( require( 'hash' ).hash )
local keys = require( 'keys' )
local network = require( 'network' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local printer = require( 'moon.printer' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )
local xdelta = require( 'moon.xdelta' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local dec_if_positive = assert( ru.dec_if_positive )
local machine_label = assert( network.machine_label )
local compress = assert( compression.compress )
local decompress = assert( compression.decompress )
local set_hash = assert( ru.set_hash )

local debug = assert( logger.debug )
local err = assert( logger.err )
local warn = assert( logger.warn )
local trace = assert( logger.trace )
local printfln = assert( printer.printfln )
local timeit = assert( time.timeit_micros )
local now_seconds = assert( time.now_seconds )
local unwords = assert( str.unwords )

local format = assert( string.format )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
local PID<const> = assert( posix.getpid().pid )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
-- data is uncompressed here.
local function create_blob( data )
  assert( type( data ) == 'string', 'invalid data' )
  -- NOTE: this will log its own compression time.
  local compressed = assert( compress( data ) )
  local hash = assert( hasher( compressed ) )
  return {
    hash=hash, --
    compressed=true, --
    data=compressed, --
  }
end

local function blob_data( blob )
  local data = assert( blob.data )
  if blob.compressed then
    return decompress( data )
  else
    return data
  end
end

local function create_delta( base_blob, new_blob )
  assert( type( base_blob ) == 'table', 'invalid base_blob' )
  assert( type( new_blob ) == 'table', 'invalid new_blob' )
  -- This will decompress.
  local base = assert( blob_data( base_blob ) )
  local new = assert( blob_data( new_blob ) )
  assert( type( base ) == 'string', 'invalid base' )
  assert( type( new ) == 'string', 'invalid new' )
  local diff = assert( xdelta.encode( base, new ) )
  local blob_base = create_blob( base )
  local blob_diff = create_blob( diff )
  local hash_base = assert( blob_base.hash )
  local hash_diff = assert( blob_diff.hash )
  local hash_manifest = assert( hasher{ hash_base, hash_diff } )
  -- This hash_new can be optionally used by the remote worker to
  -- check the result after applying the diff as a sanity check.
  local hash_new = assert( hasher( new ) )
  local manifest = {
    hash=hash_manifest,
    hash_base=hash_base,
    hash_diff=hash_diff,
    hash_new=hash_new,
  }
  local delta = {
    manifest=manifest, --
    blob_base=blob_base, --
    blob_diff=blob_diff, --
  }
  return delta
end

local function upload_delta_manifest( cxn, manifest )
  assert( type( manifest ) == 'table', 'invalid manifest' )
  local key = keys.delta( assert( manifest.hash ) )
  if not cxn:exists( key ) then
    debug( 'uploading delta manifest for %s', manifest.hash )
    local time_taken = timeit( function()
      set_hash( cxn, key, {
        hash_base=assert( manifest.hash_base ),
        hash_diff=assert( manifest.hash_diff ),
        hash_new=assert( manifest.hash_new ),
      } )
    end )
    debug( 'upload time: %d us', time_taken )
  end
  return manifest
end

-- Force is useful because when we know we need to upload it we
-- can save a ping to redis to check if it already exists.
local function upload_blob( cxn, blob, opts )
  opts = opts or {}
  local force = opts.force
  local ex = opts.ex
  assert( type( blob ) == 'table', 'invalid blob' )
  local data = assert( blob.data )
  local key = keys.blob( assert( blob.hash ) )
  if force or not cxn:exists( key ) then
    debug( 'uploading blob of size %d', #data )
    local time_taken = timeit( function()
      set_hash( cxn, key, blob, ex )
    end )
    debug( 'upload time: %d us', time_taken )
  end
  return blob
end

local function upload_delta( cxn, delta )
  -- NOTE: we don't upload the base blob because the assumption
  -- is that when we're using a delta it is because the base blob
  -- already exists there. We could enable this because
  -- upload_blob will not reupload if it already exists, but that
  -- requires another ping to redis.
  --
  --   upload_blob( cxn, delta.blob_base )
  upload_blob( cxn, delta.blob_diff )
  upload_delta_manifest( cxn, delta.manifest )
end

local function set_blob_from_string( cxn, body, ex )
  return upload_blob( cxn, assert( create_blob( body ) ),
                      { ex=ex } )
end

local function create_blob_from_file( fname )
  assert( fname, 'invalid filename' )
  local f<close> = assert( io.open( fname, 'r' ) )
  debug( 'reading file %s', fname )
  local body = f:read( 'a' )
  return create_blob( body )
end

local function set_blob_from_file( cxn, fname, ex )
  local blob = assert( create_blob_from_file( fname ) )
  return upload_blob( cxn, blob, { ex=ex } )
end

-- Reports errors via return value.
local function download_blob( cxn, blob_hash )
  assert( type( blob_hash ) == 'string' )
  debug( 'downloading blob: %s', blob_hash )
  local key = keys.blob( blob_hash )
  local time_taken, blob = timeit( function()
    return cxn:hgetall( key )
  end )
  debug( 'download time: %d us', time_taken )
  -- Note that a non-existent blob will still return a lua table
  -- from this API, so we need to check the contents as well.
  if not blob or not blob.hash then
    -- This could happen if the blob got evicted.
    return false,
           format( 'non-existent blob for hash %s', blob_hash )
  end
  assert( type( blob ) == 'table',
          format( 'unexpected blob type: %s for key: %s',
                  type( blob ), key ) )
  local data = assert( blob.data )
  if blob.compressed then
    -- NOTE: this will log its own decompression time.
    return decompress( data )
  else
    return data
  end
end

local function download_delta( cxn, delta_hash )
  assert( type( delta_hash ) == 'string' )
  debug( 'downloading delta: %s', delta_hash )
  local key = keys.delta( delta_hash )
  local time_taken, manifest = timeit( function()
    return cxn:hgetall( key )
  end )
  debug( 'download time: %d us', time_taken )
  -- Note that a non-existent manifest will still return a lua
  -- table from this API, so we need to check the contents as
  -- well.
  if not manifest or not manifest.hash_base then
    error( format( 'non-existent delta manifest for hash %s',
                   delta_hash ) )
  end
  assert( type( manifest ) == 'table',
          format( 'unexpected manifest type: %s for key: %s',
                  type( manifest ), key ) )
  local hash_base = assert( manifest.hash_base )
  local hash_diff = assert( manifest.hash_diff )
  local hash_new = assert( manifest.hash_new )
  local base_data = assert( download_blob( cxn, hash_base ) )
  local diff_data = assert( download_blob( cxn, hash_diff ) )
  local new_data =
      assert( xdelta.decode( base_data, diff_data ) )
  local hash_new_checksum = hasher( new_data )
  if hash_new_checksum ~= hash_new then
    error( format(
               'checksum failed after applying diff: %s != %s',
               hash_new_checksum, hash_new ) )
  end
  return new_data
end

local function blob_exists( cxn, blob_hash )
  local key = keys.blob( blob_hash )
  return cxn:exists( key )
end

-- Reports errors via return value.
local function download_blob_to_file( cxn, blob_hash, ofile )
  assert( type( blob_hash ) == 'string' )
  -- This could fail due to an eviction, which we want to allow
  -- for. But if we fail to open the file below then we throw an
  -- error since the latter is not supposed to happen.
  local data, reason = download_blob( cxn, blob_hash )
  if not data then return false, reason end
  local f<close> = assert( io.open( ofile, 'w' ) )
  f:write( data )
  return true
end

local function download_artifact( cxn, artifact )
  assert( cxn )
  assert( type( artifact ) == 'table' )
  local hash = assert( artifact.hash )
  local repr = assert( artifact.type )
  if repr == 'blob' then
    return assert( download_blob( cxn, hash ) )
  elseif repr == 'delta' then
    return assert( download_delta( cxn, hash ) )
  else
    error( format( 'unrecognized artifact repr: %s', repr ) )
  end
end

local function broadcast_worker_presence( cxn, set )
  local key, ex =
      keys.worker_presence_set( machine_label(), set )
  assert( ex )
  cxn:pipeline( function( p )
    p:sadd( key, PID )
    p:expire( key, ex )
  end )
  trace( 'added presence: %s|%s', key, PID )
end

local function remove_worker_presence( cxn, set, pid )
  pid = pid or PID
  local key = keys.worker_presence_set( machine_label(), set )
  -- Don't assert here just in case the set no longer exists.
  cxn:srem( key, pid )
  trace( 'removed presence: %s|%s', key, pid )
end

local function update_log_level( cxn )
  trace( 'checking for log level command...' )
  local key = assert( keys.log_level( machine_label() ) )
  local new_level = cxn:get( key )
  if not new_level then return end
  local value = logger.levels[new_level]
  if not value then
    err( 'invalid log level received: %s', new_level )
    -- We need to remove it here because 1) any other processes
    -- on this node won't be able to process it either, and 2) we
    -- don't want to keep trying.
    cxn:del( key )
    return
  end
  assert( type( value ) == 'number' )
  local cur_level = assert( logger.level )
  if value == cur_level then
    trace( 'log level already at %s', new_level )
    return
  end
  -- Do this with print so that it goes out regardless of what
  -- the log level currently is.
  printfln( 'INFO >>> setting log level to %s', new_level )
  io.flush()
  logger.level = assert( value )
  -- NOTE: we do not erase the key from the db here because there
  -- may be other processes on the host that need to read it.
end

local LAST_LOG_LEVEL_UPDATE_CHECK = 0
local function check_log_level( cxn )
  local now = now_seconds()
  local next = LAST_LOG_LEVEL_UPDATE_CHECK +
                   config.general.UPDATE_LOG_LEVEL_INTERVAL_SECS
  if now < next then return end
  LAST_LOG_LEVEL_UPDATE_CHECK = now
  update_log_level( cxn )
end

-----------------------------------------------------------------
-- WorkerCount
-----------------------------------------------------------------
local WorkerCount = {}
WorkerCount.__index = WorkerCount

function WorkerCount:key()
  return keys.node_worker_target_count( self._node, self._label )
end

function WorkerCount:get()
  return tonumber( self._cxn:get( self:key() ) or 0 )
end

function WorkerCount:set( count )
  assert( count, 'missing count' )
  return self._cxn:set( self:key(), count )
end

function WorkerCount:inc() return self._cxn:incr( self:key() ) end

function WorkerCount:dec()
  return dec_if_positive( self._cxn, self:key() )
end

function WorkerCount.new( cxn, node, label )
  assert( cxn, 'missing cxn' )
  assert( node, 'missing node' )
  assert( label, 'missing label' )
  local o = { _cxn=cxn, _node=node, _label=label }
  return setmetatable( o, WorkerCount )
end

local function reset_task_input_and_output( cxn )
  local function del( pattern )
    assert( pattern )
    assert( pattern:find( '*' ) )
    warn( 'deleting keys: %s', pattern )
    -- Delete in groups otherwise too slow.
    while true do
      local all = cxn:keys( pattern )
      assert( type( all ) == 'table' )
      if #all == 0 then return end
      local some = {}
      for i = 1, 1000 do
        if all[i] then
          some[i] = all[i]
        else
          break
        end
      end
      cxn:raw_cmd( format( 'del %s', unwords( some ) ) )
    end
  end
  del( keys.node_ctl( '*' ) )
  del( keys.blob( '*' ) )
  del( keys.delta( '*' ) )
  del( keys.task( '*' ) )
  del( keys.queue() .. ':*' )
  del( keys.events() .. ':*' )
  del( keys.node_worker_deaths( '*' ) )
  return true
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  blob_exists=blob_exists,
  blob_data=blob_data,
  create_blob=create_blob,
  create_blob_from_file=create_blob_from_file,
  upload_blob=upload_blob,
  download_blob=download_blob,
  set_blob_from_string=set_blob_from_string,
  set_blob_from_file=set_blob_from_file,
  download_blob_to_file=download_blob_to_file,
  create_delta=create_delta,
  upload_delta=upload_delta,
  download_artifact=download_artifact,
  broadcast_worker_presence=broadcast_worker_presence,
  remove_worker_presence=remove_worker_presence,
  WorkerCount=WorkerCount.new,
  check_log_level=check_log_level,
  reset_task_input_and_output=reset_task_input_and_output,
}
