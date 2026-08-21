-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local compilers = require( 'compilers' )
-- local config = require( 'config' )
local os_stat = require( 'os-stat' )
local decode = require( 'decode' )
local redist = require( 'redist' )
local subprocess = require( 'subprocess' )

local logger = require( 'moon.logger' )

local argparse = require( 'argparse' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local os_version = assert( os_stat.os_version )
local cdecode = assert( decode.cdecode )
local cvalidate = assert( decode.cvalidate )
local popen = assert( subprocess.popen )
local match_compiler = assert( compilers.match_compiler )

local info = assert( logger.info )
local warn = assert( logger.warn )

-- local concat = assert( table.concat )
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

local function analyze_command( command )
  assert( type( command ) == 'string' )
  local decoded = assert( cdecode( command ) )
  -- This does mechanical validation that just checks if the com-
  -- mand is self-consistent and generally a valid command, even
  -- if it is not something that we specifically support.
  cvalidate( decoded )
  local compiler_match =
      assert( match_compiler( decoded.binary ) )

  if decoded.special_flags.E then
    -- Although we do do a preprocess before we distribute, we
    -- are not supposed to receive a preprocess command outright.
    error( 'cannot distribute preprocess commands' )
  end

  if not decoded.special_flags.c then
    error( '-c not found in compile command' )
  end

  if not decoded.special_flags.o then
    -- It is possible that some commands may work without an ex-
    -- plicit -o flag (i.e. will use some default way of deducing
    -- the output file) but that will not work for us because we
    -- need to know where to put the result.
    error( '-o not found in compile command' )
  end

  if #decoded.input_object_files > 0 then
    error( 'cannot distribute linker commands' )
  end

  if #decoded.input_c_cpp_files ~= 1 then
    error( 'expected exactly one c/cpp file as input' )
  end

  return {
    raw=command,
    decoded=decoded,
    compiler_match=compiler_match,
  }
end

local function create_remote_task( analyzed )
  local parsed = assert( analyzed.parsed )
  local interpreted = assert( analyzed.interpreted )
  -- Create a task.
  return {
    compiler_flags=assert( parsed.flags ),
    compiler_type=assert( interpreted.compiler_type ),
    compiler_version=assert( interpreted.compiler_version ),
    description=assert( parsed.compile ),
    input=nil, -- filled in later after preprocessing.
    os=os_version(),
  }
end

local function run_local( command )
  info( 'running command: %s', command )
  local elems = command:split( '%s+' )
  local prog = assert( elems[1] )
  table.remove( elems, 1 )
  local params = elems
  local opts = { use_path_env=true }
  local status, stdout, stderr, reason =
      popen( prog, params, opts )
  if status ~= 0 and reason ~= 'exited' then
    warn( 'command exited for reason: %s', reason )
  end
  assert( io.stdout ):write( stdout )
  assert( io.stderr ):write( stderr )
  os.exit( status )
end

local function run_remote( cxn, analyzed )
  local task = assert( create_remote_task( analyzed ) )
  -- TODO
  run_local( analyzed.unparsed )
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
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
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  -- Let's do this here to fail fast if we can't determine it.
  assert( os_version(), 'cannot determine os version tag' )

  local cxn = assert( redist.connect() )

  local command = assert( args.command )
  local analyzed = assert( analyze_command( command ) )
  run_local( command )
  -- run_remote( cxn, analyzed )

  return 0
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
