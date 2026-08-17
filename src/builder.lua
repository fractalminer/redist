-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local compilers = require( 'compilers' )
local config = require( 'config' )
local os_stat = require( 'os-stat' )
local cparse = require( 'cparse' )
local redist = require( 'redist' )

local logger = require( 'moon.logger' )

local argparse = require( 'argparse' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local os_version = assert( os_stat.os_version )
local cdecode = assert( cparse.cdecode )

local concat = assert( table.concat )
local format = assert( string.format )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
-- TODO

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
-- Parsed CLI args will be put here.
local args

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function ping( cxn )
  assert( cxn:ping(), 'lost connection to redis server' )
end

local function parse_compile_cmd( command )
  assert( type( command ) == 'string' )
  local compile_info, reason = cdecode( command )
  if not compile_info then return false, reason end
  if not compile_info.compiler then
    return false, 'cannot extract compiler'
  end
  if compile_info.preprocess then
    return false, 'cannot distribute preprocess commands'
  end
  if not compile_info.compile then
    return false, 'missing compile input (-c)'
  end
  if not compile_info.output then
    return false, 'missing compile output (-o)'
  end
  return compile_info
end

local function always_run_local( command )
  assert( type( command ) == 'string' )
  local compile_info, reason = cdecode( command )
  if not compile_info then return false, reason end
  if not compile_info.compiler then
    return false, 'cannot extract compiler'
  end
  if compile_info.preprocess then
    return false, 'cannot distribute preprocess commands'
  end
  if not compile_info.compile then
    return false, 'missing compile input (-c)'
  end
  if not compile_info.output then
    return false, 'missing compile output (-o)'
  end
  return compile_info
end

local function can_distribute( command )
  local parsed, reason = parse_compile_cmd( command )
  if not parsed then return false, reason end
  local identification, reason2 =
      compilers.interpret( parsed.compiler )
  if not identification then return false, reason2 end
  -- Create a task.
  return {
    compiler_flags=assert( parsed.flags ),
    compiler_type=assert( identification.compiler_type ),
    compiler_version=assert( identification.compiler_version ),
    description=assert( parsed.compile ),
    input=nil, -- filled in later after preprocessing.
    os=os_version(),
  }
end

local function run_local( command ) end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main( ... )
  local parser = argparse( arg[0],
                           'ReDist Distributed Build Launcher' )

  -- LuaFormatter off
  parser:option( '--command' )
        :args( 1 )
        :count( 1 )
        :description( 'command to run' )

  parser:option( '--verbosity' )
        :choices{ 'error', 'warning', 'info', 'debug', 'trace' }
        :default( 'warning' )
        :description( 'log level' )

  parser:option( '--workarea' )
        :default( '/tmp' )
        :description( 'where temporary files are stored' )

  parser:option( '-m --mode' )
        :choices{ 'strict', 'permissive' }
        :default( 'strict' )
        :description( 'whether to allow running commands that cannot be distributed' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  -- Let's do this here to fail fast if we can't determine it.
  assert( os_version(), 'cannot determine os version tag' )

  local cxn = assert( redist.connect() )

  local command = assert( args.command )
  local dist_info, no_dist_reason = can_distribute( command )
  if not dist_info then
    if args.mode == 'strict' then
      error( format(
                 'error: cannot distribute.\nreason: %s\ncommand: %s',
                 no_dist_reason, command ) )
    end
    return run_local( command )
  end

  return 0
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main( ... ) )
