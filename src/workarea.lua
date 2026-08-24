-----------------------------------------------------------------
-- Helpers for temporary files in the workarea.
-----------------------------------------------------------------
local file = require( 'moon.file' )
local logger = require( 'moon.logger' )
local mcleanup = require( 'moon.cleanup' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local cleanup = assert( mcleanup.cleanup )
local err = assert( logger.err )
local exists = assert( file.exists )
local trace = assert( logger.trace )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
-- Returns a closable value.
local function remove_when_done( fname )
  assert( type( fname ) == 'string' )
  return cleanup( function()
    if not exists( fname ) then return end
    trace( 'removing temporary file: ' .. fname )
    local ok = os.remove( fname )
    -- Since we're already in a __close method here we'll just
    -- log the error.
    if not ok then err( 'failed to remove file: %s', fname ) end
  end )
end

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return { remove_when_done=remove_when_done }
