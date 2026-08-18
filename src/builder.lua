-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local compilers = require( 'compilers' )
-- local config = require( 'config' )
local os_stat = require( 'os-stat' )
local cparse = require( 'cparse' )
local redist = require( 'redist' )
local subprocess = require( 'subprocess' )

local logger = require( 'moon.logger' )

local argparse = require( 'argparse' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local os_version = assert( os_stat.os_version )
local cdecode = assert( cparse.cdecode )
local popen = assert( subprocess.popen )

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
  local parsed, err = cdecode( command )
  if not parsed then return false, err end
  local analyzed = {
    parsed=parsed, --
    unparsed=command, --
    label=nil, --
    interpreted=nil, --
  }
  if not parsed.compiler then
    err = 'missing compiler binary'
  elseif not parsed.output then
    err = 'missing compile output (-o)'
  elseif not parsed.compile and parsed.preprocess then
    analyzed.label = 'preprocess'
  elseif not parsed.compile and parsed.object_files then
    analyzed.label = 'link'
  elseif parsed.compile then
    analyzed.label = 'compile'
  end
  if err then return false, err end
  analyzed.interpreted, err = compilers.interpret(
                                  parsed.compiler )
  if not analyzed.interpreted then return false, err end
  return analyzed
end

local function how_to_run( analyzed )
  if analyzed.label == 'preprocess' then
    -- Although this builder will run a preprocessor command as
    -- part of preparing a compilation task, it cannot run a pre-
    -- process command itself as the target command.
    return false, 'cannot run preprocessor commands'
  elseif analyzed.label == 'link' then
    return 'local'
  elseif analyzed.label == 'compile' then
    return 'remote'
  else
    return false,
           format( 'unrecognized label: %s', analyzed.label )
  end
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
  local how = assert( how_to_run( analyzed ) )
  if how == 'local' then
    run_local( command )
  elseif how == 'remote' then
    run_remote( cxn, analyzed )
  else
    error( format( 'unrecognized run mode: %s', how ) )
  end

  return 0
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
