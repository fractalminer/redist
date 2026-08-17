-----------------------------------------------------------------
-- General redis-lua utilities.
-----------------------------------------------------------------
local config = require( 'config' )
local redis = require( 'redis' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local HOST = assert( config.general.HOST )
local PORT = assert( config.general.PORT )

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function connect()
  local cxn = assert( redis.connect( HOST, PORT ) )
  assert( cxn:ping(), 'unable to ping redis server' )
  return cxn
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  connect=connect, --
}
