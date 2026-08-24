-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local hash = require( 'hash' )

local logger = require( 'moon.logger' )
local time = require( 'moon.time' )

local zlib = require( 'zlib' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )
local timeit = assert( time.timeit_micros )

local format = assert( string.format )

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

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  blob_exists=blob_exists, --
  download_blob=download_blob, --
  set_blob=set_blob, --
  set_blob_from_file=set_blob_from_file, --
  download_blob_to_file=download_blob_to_file, --
}
