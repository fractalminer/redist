-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local hash = require( 'hash' )

local logger = require( 'moon.logger' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function set_blob( cxn, body )
  assert( body, 'invalid body' )
  local h = hash.hash( body )
  local key = format( 'farm:blob:%s', h )
  if not cxn:exists( key ) then
    debug( 'uploading blob of size %d', #body )
    cxn:set( key, body )
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
  debug( 'finding blob: %s', blob_hash )
  local key = format( 'farm:blob:%s', blob_hash )
  local blob = cxn:get( key )
  if not blob then
    error( format( 'blob not found for key %s', key ) )
  end
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
