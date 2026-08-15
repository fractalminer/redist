-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local cityhash = require( 'cityhash' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local format = string.format
local byte = string.byte

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function hex( str )
  return str:gsub( '.', function( c )
    return format( '%02x', byte( c ) )
  end )
end

local function hash( data )
  assert( type( data ) == 'string', 'hash data is invalid' )
  local res, len = hex( cityhash.hash128( data, #data ) )
  assert( len == 16 )
  return res
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return { hash=hash }