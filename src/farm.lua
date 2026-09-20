-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local compression = require( 'compression' )
local config = require( 'config' )
local hash = assert( require( 'hash' ).hash )
local keys = require( 'keys' )
local network = require( 'network' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local time = require( 'moon.time' )

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
local timeit = assert( time.timeit_micros )
local trace = assert( logger.trace )

local format = assert( string.format )

-----------------------------------------------------------------
-- Config Fields.
-----------------------------------------------------------------
local EXPIRE_ADVERTISE_SECS = config.worker.EXPIRE_ADVERTISE_SECS

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
  local h = assert( hash( compressed ) )
  return {
    hash=h, --
    compressed=true, --
    data=compressed, --
  }
end

local function create_delta( base, diff )
  assert( type( base ) == 'string', 'invalid base' )
  assert( type( diff ) == 'string', 'invalid diff' )
  local blob_base = create_blob( base )
  local blob_diff = create_blob( diff )
  local hash_base = assert( blob_base.hash )
  local hash_diff = assert( blob_diff.hash )
  local hash_manifest = assert( hash{ hash_base, hash_diff } )
  local manifest = {
    hash=hash_manifest, --
    hash_bash=hash_base, --
    hash_diff=hash_diff, --
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
        hash_base=assert( manifest.hash_base ), --
        hash_diff=assert( manifest.hash_diff ), --
      } )
    end )
    debug( 'upload time: %d us', time_taken )
  end
  return manifest
end

local function upload_blob( cxn, blob )
  assert( type( blob ) == 'table', 'invalid blob' )
  local data = assert( blob.data )
  local key = keys.blob( assert( blob.hash ) )
  if not cxn:exists( key ) then
    debug( 'uploading blob of size %d', #data )
    local time_taken = timeit( function()
      set_hash( cxn, key, blob )
    end )
    debug( 'upload time: %d us', time_taken )
  end
  return blob
end

local function upload_delta( cxn, delta )
  upload_blob( cxn, delta.blob_base )
  upload_blob( cxn, delta.blob_diff )
  upload_delta_manifest( cxn, delta.manifest )
  return delta
end

local function set_blob_from_string( cxn, body )
  return upload_blob( cxn, assert( create_blob( body ) ) )
end

local function create_blob_from_file( fname )
  assert( fname, 'invalid filename' )
  local f<close> = assert( io.open( fname, 'r' ) )
  debug( 'reading file %s', fname )
  local body = f:read( 'a' )
  return create_blob( body )
end

local function set_blob_from_file( cxn, fname )
  local blob = assert( create_blob_from_file( fname ) )
  return upload_blob( cxn, blob )
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

local function broadcast_worker_presence( cxn, set )
  local key = keys.worker_presence_set( machine_label(), set )
  assert( cxn:sadd( key, PID ) )
  cxn:expire( key, EXPIRE_ADVERTISE_SECS )
  trace( 'added presence: %s|%s', key, PID )
end

local function remove_worker_presence( cxn, set )
  local key = keys.worker_presence_set( machine_label(), set )
  -- Don't assert here just in case the set no longer exists.
  cxn:srem( key, PID )
  trace( 'removed presence: %s|%s', key, PID )
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

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  blob_exists=blob_exists,
  create_blob=create_blob,
  download_blob=download_blob,
  set_blob_from_string=set_blob_from_string,
  set_blob_from_file=set_blob_from_file,
  download_blob_to_file=download_blob_to_file,
  broadcast_worker_presence=broadcast_worker_presence,
  remove_worker_presence=remove_worker_presence,
  WorkerCount=WorkerCount.new,
}
