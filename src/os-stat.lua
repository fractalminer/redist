-- OS Version Finder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local str = require( 'moon.str' )
local file = require( 'moon.file' )
local logger = require( 'moon.logger' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local read_lines = assert( file.read_lines )
local debug = assert( logger.debug )

local stat = assert( posix.sys.stat.stat )

local format = string.format

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local POP_OS_RELEASE = '/etc/pop-os/os-release'

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

-- Clearly this won't change while the program is running.
local cached_os_version = nil

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function os_version_impl()
  debug( 'looking for OS version...' )
  if stat( POP_OS_RELEASE ) then
    debug( 'looking for Pop!_OS version...' )
    local lines = read_lines( POP_OS_RELEASE )
    for _, line in ipairs( lines ) do
      local ver = line:match( '^VERSION_ID="([0-9.]+)"$' )
      if ver then
        ver = ver:gsub( '%.', '_' )
        ver = format( 'pop_%s', ver )
        debug( 'found version: %s', ver )
        return ver
      end
    end
  end
  -- Add more here...
end

local function os_version()
  if cached_os_version then return cached_os_version end
  if cached_os_version == false then
    -- We've already tried but failed to find the os version.
    return nil
  end
  local ver = os_version_impl()
  if ver then
    cached_os_version = ver
    return ver
  end
  cached_os_version = false
  return nil
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return { os_version=os_version }
