-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local compilers = require( 'compilers' )
local os_stat = require( 'os-stat' )
local decode = require( 'decode' )
local redist = require( 'redist' )

local colors = require( 'moon.colors' )
local logger = require( 'moon.logger' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local os_version = assert( os_stat.os_version )
local cround_trip = assert( decode.cround_trip )
local match_compiler = assert( compilers.match_compiler )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
-- TODO

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
logger.level = assert( logger.levels.WARNING )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function ping( cxn )
  assert( cxn:ping(), 'lost connection to redis server' )
end

local function analyze_command( command )
  assert( type( command ) == 'table' ) -- list
  local decoded = assert( cround_trip( command ) )
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
  local decoded = assert( analyzed.decoded )
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

local function run_remote( cxn, analyzed )
  local task = assert( create_remote_task( analyzed ) )
  -- TODO
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  -- Let's do this here to fail fast if we can't determine it.
  assert( os_version(), 'cannot determine os version tag' )

  local cxn = assert( redist.connect() )

  local command = assert( arg )
  local analyzed = assert( analyze_command( command ) )
  run_remote( cxn, analyzed )

  return 0
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
