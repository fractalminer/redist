-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local config = require( 'config' )
local hash = require( 'hash' )
local network = require( 'network' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local time = require( 'moon.time' )

local zlib = require( 'zlib' )
local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local dec_if_positive = assert( ru.dec_if_positive )
local machine_label = assert( network.machine_label )

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
local function compress( what )
  local deflate = zlib.deflate( assert( 1 ) )
  local time_taken, compressed =
      timeit( function() return (deflate( what, 'finish' )) end )
  debug( 'compression time: %d us', time_taken )
  return compressed
end

local function decompress( what )
  ---@diagnostic disable-next-line: missing-parameter
  local inflate = zlib.inflate()
  local time_taken, decompressed =
      timeit( function() return (inflate( what )) end )
  debug( 'decompression time: %d us', time_taken )
  return decompressed
end

local function set_blob( cxn, body )
  assert( body, 'invalid body' )
  local h = hash.hash( body )
  local key = format( 'farm:blob:%s', h )
  if not cxn:exists( key ) then
    debug( 'uploading blob of size %d', #body )
    local time_taken = timeit( function()
      cxn:set( key, compress( body ) )
    end )
    debug( 'upload time: %d us', time_taken )
  end
  return h
end

local function set_blob_from_file( cxn, fname )
  assert( fname, 'invalid filename: ' .. fname )
  local f<close> = assert( io.open( fname, 'r' ) )
  debug( 'reading file %s', fname )
  local body = f:read( 'a' )
  return set_blob( cxn, body )
end

local function download_blob( cxn, blob_hash )
  debug( 'downloading blob: %s', blob_hash )
  local key = format( 'farm:blob:%s', blob_hash )
  local time_taken, blob = timeit( function()
    return cxn:get( key )
  end )
  debug( 'download time: %d us', time_taken )
  if not blob then
    error( format( 'blob not found for key %s', key ) )
  end
  blob = decompress( blob )
  assert( type( blob ) == 'string',
          format( 'unexpected blob type: %s for key: %s',
                  type( blob ), key ) )
  return blob
end

local function blob_exists( cxn, blob_hash )
  local key = format( 'farm:blob:%s', blob_hash )
  return cxn:exists( key )
end

local function download_blob_to_file( cxn, blob_hash, ofile )
  local blob = assert( download_blob( cxn, blob_hash ) )
  local f<close> = assert( io.open( ofile, 'w' ) )
  f:write( blob )
  return true
end

local function broadcast_presence( cxn, set )
  local key = 'farm:node:%s:presence:%s'
  key = key:format( machine_label(), set )
  assert( cxn:sadd( key, PID ) )
  cxn:expire( key, EXPIRE_ADVERTISE_SECS )
  trace( 'added presence: %s|%s', key, PID )
end

local function remove_presence( cxn, set )
  local key = 'farm:node:%s:presence:%s'
  key = key:format( machine_label(), set )
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
  return format( 'farm:node:%s:target_count:%s', self._node,
                 self._label )
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
  download_blob=download_blob,
  set_blob=set_blob,
  set_blob_from_file=set_blob_from_file,
  download_blob_to_file=download_blob_to_file,
  broadcast_presence=broadcast_presence,
  remove_presence=remove_presence,
  WorkerCount=WorkerCount.new,
}
