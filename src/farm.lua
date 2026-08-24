-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local hash = require( 'hash' )

local logger = require( 'moon.logger' )

local zlib = require( 'zlib' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function compress( what )
  local deflate = zlib.deflate( assert( 1 ) )
  return (deflate( what, 'finish' ))
end

local function decompress( what )
  local inflate = zlib.inflate()
  return (inflate( what ))
end

local function set_blob( cxn, body )
  assert( body, 'invalid body' )
  local h = hash.hash( body )
  local key = format( 'farm:blob:%s', h )
  if not cxn:exists( key ) then
    debug( 'uploading blob of size %d', #body )
    cxn:set( key, compress( body ) )
    debug( 'finished uploading blob' )
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
  local blob = cxn:get( key )
  debug( 'finished downloading blob: %s', blob_hash )
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
