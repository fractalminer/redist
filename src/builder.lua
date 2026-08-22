-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local compilers = require( 'compilers' )
local decode = require( 'decode' )
local hash = require( 'hash' )
local ltask = require( 'local-task' )
local network = require( 'network' )
local os_stat = require( 'os-stat' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local tbl = require( 'moon.tbl' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local cencode = assert( decode.cencode )
local cround_trip = assert( decode.cround_trip )
local machine_id = assert( network.machine_id )
local match_compiler = assert( compilers.match_compiler )
local os_version = assert( os_stat.os_version )

local deep_copy = assert( tbl.deep_copy )

local getcwd = assert( posix.unistd.getcwd )

local format = assert( string.format )
local concat = assert( table.concat )
local remove = assert( table.remove )

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
  if not decoded.input_c_cpp_file then
    error( 'expected a c/cpp file as input' )
  end

  return {
    raw=command,
    decoded=decoded,
    compiler_match=compiler_match,
  }
end

local function create_local_preprocess_task( cxn, analyzed )
  local decoded = deep_copy( assert( analyzed.decoded ) )
  -- require( 'moon.json' ).print( decoded )
  assert( decoded.special_flags.c )
  assert( decoded.special_flags.o )
  assert( decoded.input_c_cpp_file )
  assert( not decoded.special_flags.E )
  decoded.special_flags.c = false
  decoded.special_flags.E = true
  local c = assert( decoded.input_c_cpp_file )

  -- Put the .ii file next to where the .o would go.
  -- TODO: factor this out and improve it.
  c = c:split( '/' )
  c = c[#c]
  local o = assert( decoded.special_flags.o )
  o = o:split( '/' )
  remove( o )
  o = concat( o, '/' )

  decoded.special_flags.o = format( '%s/%s.ii', o, c )
  local command = concat( cencode( decoded ), ' ' )
  assert( io.stderr ):write( format( 'command: %s\n', command ) )
  local cwd = getcwd()

  -- FIXME: improve this
  local profile = command .. cwd .. machine_id()

  local task_hash = hash.hash( profile )
  ltask.create_task( cxn, task_hash, {
    command=command,
    cwd=cwd,
    description=format( 'preprocess %s', decoded.input_c_cpp_file ),
  } )
  return task_hash
end

-- local function create_remote_compile_task( analyzed )
--   local decoded = assert( analyzed.decoded )
--   local interpreted = assert( analyzed.interpreted )
--   -- Create a task.
--   return {
--     compiler_flags=assert( parsed.flags ),
--     compiler_type=assert( interpreted.compiler_type ),
--     compiler_version=assert( interpreted.compiler_version ),
--     description=assert( parsed.compile ),
--     input=nil, -- filled in later after preprocessing.
--     os=os_version(),
--   }
-- end

local function run( cxn, analyzed )
  local preprocess_task_hash = create_local_preprocess_task( cxn,
                                                             analyzed )
  ltask.post_task( cxn, preprocess_task_hash )
  error( 'not implemented' )
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  -- Let's do this here to fail fast if we can't determine it.
  assert( os_version(), 'cannot determine os version tag' )

  local cxn = assert( ru.connect() )

  local command = assert( arg )
  local analyzed = assert( analyze_command( command ) )
  run( cxn, analyzed )

  return 0
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
