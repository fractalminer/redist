-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local cityhash = require( 'cityhash' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local format = assert( string.format )
local byte = assert( string.byte )
local concat = assert( table.concat )

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function hex( str )
  return str:gsub( '.', function( c )
    return format( '%02x', byte( c ) )
  end )
end

-- Accepts either a string or a list of strings.
local function hash( data )
  if type( data ) == 'table' then data = concat( data, ' ' ) end
  assert( type( data ) == 'string', 'hash data is invalid' )
  local res, len = hex( cityhash.hash128( data, #data ) )
  assert( len == 16 )
  return res
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return { hash=hash }