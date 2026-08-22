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
  if not cxn:exists( key ) then cxn:set( key, body ) end
  return h
end

local function find_blob( cxn, blob_hash )
  debug( 'finding blob: %s', blob_hash )
  local key = format( 'farm:blob:%s', blob_hash )
  local blob = cxn:get( key )
  assert( type( blob ) == 'string', 'unexpected blob type' )
  return blob
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  find_blob=find_blob, --
  set_blob=set_blob, --
}
