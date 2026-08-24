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
-- For e.g. a binary of:
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
local function match_clang_tools( binary, info )
  if not binary:match( 'tools' ) then return end
  if not binary:match( 'clang' ) then return end
  if not binary:match( 'llvm' ) then return end
  local resolved = realpath( binary )
  if not resolved then
    return false, format( 'failed to resolve %s', binary )
  end
  local version = resolved:match( 'llvm[^/]*%-([0-9.]+)/' )
  if not version then
    return false, format(
               'failed to find version of compiler %s', resolved )
  end
  assert( type( version ) == 'string' )
  local base = binary:match( '++$' ) and 'clang++' or 'clang'
  info.compiler_type = format( '%s-tools', base )
  info.compiler_version = version
  return true
end

-- Compiler: gnu
--
-- For e.g. a binary of:
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
local function match_gcc_tools( binary, info )
  if not binary:match( 'tools' ) then return end
  if not binary:match( 'gcc-' ) then return end
  local resolved = realpath( binary )
  if not resolved then
    return false, format( 'failed to resolve %s', binary )
  end
  local version = resolved:match( 'gcc%-([0-9.]+)/' )
  if not version then
    return false, format(
               'failed to find version of compiler %s', resolved )
  end
  assert( type( version ) == 'string' )
  local base = binary:match( '++' ) and 'g++' or 'gcc'
  info.compiler_type = format( '%s-tools', base )
  info.compiler_version = version
  return true
end

-- Compiler: gnu/system
--
-- For e.g. a binary of:
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
local function match_gcc_system( binary, info )
  local os_ver = os_version()
  if not os_ver then
    -- Cannot interpret a system compiler without knowing the os
    -- version that we are on.
    return nil
  end
  if binary == '/usr/bin/gcc' or binary == '/usr/bin/cc' then
    info.compiler_type = 'gcc-system'
    info.compiler_version = os_ver
    return true
  end
  if binary == '/usr/bin/g++' or binary == '/usr/bin/c++' then
    info.compiler_type = 'g++-system'
    info.compiler_version = os_ver
    return true
  end
  return nil
end

local function match_compiler( binary )
  assert( type( binary ) == 'string' )
  binary = trim( binary )
  local info = { compiler_type=nil, compiler_version=nil }
  if match_clang_tools( binary, info ) then return info end
  if match_gcc_tools( binary, info ) then return info end
  if match_gcc_system( binary, info ) then return info end
  return false, 'unrecognized compiler: ' .. binary
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

local function pp_style( compiler_type )
  local style = {
    includes_only=false,
    pp_flags={},
    ext='.ii',
    x_pp='c++',
    x_compile='c++-cpp-output',
  }
  if compiler_type:match( 'clang' ) then
    -- For clang there is an issue where it will give noisier er-
    -- rors when it is given the preprocessed output directly (in
    -- particular, it warns about things inside of macros that
    -- would normally be suppressed because they are inside of
    -- macros). This -frewrite-includes tells clang to preprocess
    -- in the sense of inserting the #include directives so as to
    -- produce a standalone file, but to postpone evaluating the
    -- macros. This way the compile output is not too noisy.
    --
    -- NOTE: one consequence of this is that, although we can
    -- omit the -I directives when doing the compile job, we need
    -- to preserve all the -D ones.
    style = {
      includes_only=true,
      pp_flags={ '-frewrite-includes' }, --
      ext='', --
      x_pp='c++',
      x_compile='c++',
    }
  end
  return style
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  match_compiler=match_compiler,
  locate=locate,
  pp_style=pp_style,
}
