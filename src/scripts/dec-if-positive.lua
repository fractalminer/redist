-- NOTE: This is a remote redis script.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local redis = assert( _G['redis'] )
local KEYS = assert( _G['KEYS'] )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local call = assert( redis.call )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function dec_if_positive( key )
  local value = tonumber( call( 'get', key ) or 0 )
  return (value > 0) and call( 'decr', key ) or 0
end

-----------------------------------------------------------------
-- Call it.
-----------------------------------------------------------------
local key = assert( KEYS[1] )
return dec_if_positive( key )