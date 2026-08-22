-----------------------------------------------------------------
-- Helpers for dealing with ccache.
-----------------------------------------------------------------
-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
-- ccache has a strange quirk where we cannot allow the string
-- "fdiagnostics-color" to appear in the output otherwise if the
-- command fails then it will assume it is because the compiler
-- is rejecting that flag and it will retry a potentially costly
-- compilation. So we have to remove that.
local function log_command( where, ... )
  local cmd = format( ... )
  cmd = cmd:gsub( 'fdiagnostics%-color', '<hidden>' )
  where( 'command: %s', cmd )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return { log_command=log_command }
