-- Compiler Finder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local os_stat = require( 'os-stat' )

local posix = require( 'posix' )

local str = require( 'moon.str' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local os_version = assert( os_stat.os_version )

local trim = assert( str.trim )

local realpath = assert( posix.stdlib.realpath )
local stat = assert( posix.sys.stat.stat )

local format = string.format

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
-- Compiler: llvm/clang
--
-- For e.g. a cmd of:
--   /home/user/dev/tools/llvm-current/bin/clang++
--
-- resolves to:
--   /home/user/dev/tools/llvm-pgo-21.1.8/bin/clang-21
--
-- and yields:
--   {
--     compiler_type = 'clang-tools',
--     compiler_version = '21.1.8',
--   }
--
local function interpret_clang_tools( cmd, info )
  if not cmd:match( 'tools' ) then return end
  if not cmd:match( 'clang' ) then return end
  if not cmd:match( 'llvm' ) then return end
  local resolved = realpath( cmd )
  if not resolved then
    return false, format( 'failed to resolve %s', cmd )
  end
  local version = resolved:match( 'llvm[^/]*%-([0-9.]+)/' )
  if not version then
    return false, format(
               'failed to find version of compiler %s', resolved )
  end
  assert( type( version ) == 'string' )
  local base = cmd:match( '++$' ) and 'clang++' or 'clang'
  info.compiler_type = format( '%s-tools', base )
  info.compiler_version = version
  return true
end

-- Compiler: gnu
--
-- For e.g. a cmd of:
--   /home/user/dev/tools/gcc-current/bin/g++
--
-- resolves to:
--   /home/user/dev/tools/gcc-15.2.0/bin/g++
--
-- and yields:
--   {
--     compiler_type = 'g++',
--     compiler_version = '15.2.0',
--   }
--
local function interpret_gcc_tools( cmd, info )
  if not cmd:match( 'tools' ) then return end
  if not cmd:match( 'gcc-' ) then return end
  local resolved = realpath( cmd )
  if not resolved then
    return false, format( 'failed to resolve %s', cmd )
  end
  local version = resolved:match( 'gcc%-([0-9.]+)/' )
  if not version then
    return false, format(
               'failed to find version of compiler %s', resolved )
  end
  assert( type( version ) == 'string' )
  local base = cmd:match( '++' ) and 'g++' or 'gcc'
  info.compiler_type = format( '%s-tools', base )
  info.compiler_version = version
  return true
end

-- Compiler: gnu/system
--
-- For e.g. a cmd of:
--   /usr/bin/g++
--
-- yields:
--   {
--     compiler_type = 'g++-system',
--     compiler_version = '22_04',
--   }
--
-- NOTE: the compiler version is the OS version.
--
local function interpret_gcc_system( cmd, info )
  local os_ver = os_version()
  if not os_ver then
    -- Cannot interpret a system compiler without knowing the os
    -- version that we are on.
    return nil
  end
  if cmd == '/usr/bin/gcc' or cmd == '/usr/bin/cc' then
    info.compiler_type = 'gcc-system'
    info.compiler_version = os_ver
    return true
  end
  if cmd == '/usr/bin/g++' or cmd == '/usr/bin/c++' then
    info.compiler_type = 'g++-system'
    info.compiler_version = os_ver
    return true
  end
  return nil
end

local function interpret( cmd )
  assert( type( cmd ) == 'string' )
  cmd = trim( cmd )
  local info = { compiler_type=nil, compiler_version=nil }
  if interpret_clang_tools( cmd, info ) then return info end
  if interpret_gcc_tools( cmd, info ) then return info end
  if interpret_gcc_system( cmd, info ) then return info end
  return false, 'unrecognized compiler: ' .. cmd
end

local function locate( info )
  local path
  local tools_versions = {
    ['gcc-tools']='{{HOME}}/dev/tools/gcc-{{VERSION}}/bin/gcc-{{VERSION}}', --
    ['g++-tools']='{{HOME}}/dev/tools/gcc-{{VERSION}}/bin/g++-{{VERSION}}', --
    ['clang-tools']='{{HOME}}/dev/tools/llvm-pgo-{{VERSION}}/bin/clang', --
    ['clang++-tools']='{{HOME}}/dev/tools/llvm-pgo-{{VERSION}}/bin/clang++', --
  }
  local system_versions = {
    ['gcc-system']='/usr/bin/gcc', --
    ['g++-system']='/usr/bin/g++', --
  }
  assert( info.compiler_type, 'missing compiler_type' )
  assert( info.compiler_version, 'missing compiler_version' )
  assert( info.user_home, 'missing user home' )
  if info.compiler_type:match( 'tools' ) then
    path = tools_versions[info.compiler_type]
  elseif info.compiler_type:match( 'system' ) then
    local os_ver = os_version()
    if not os_ver then
      return false,
             'cannot determine of version for locating system compiler'
    end
    if os_ver ~= info.compiler_version then
      return false, 'mismatch in OS version for system compiler'
    end
    path = system_versions[info.compiler_type]
  end
  if path then
    path = path:gsub( '{{HOME}}', info.user_home )
    path = path:gsub( '{{VERSION}}', info.compiler_version )
    if not stat( path ) then
      return false, format(
                 'deduced compiler is not present: %s', path )
    end
    return path
  end
  return false, 'cannot locate compiler'
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return { interpret=interpret, locate=locate }
