-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local ccache = require( 'ccache-helper' )
local compilers = require( 'compilers' )
local decode = require( 'decode' )
local farm = require( 'farm' )
local hash = require( 'hash' )
-- TODO: consolidate these two modules.
local ltask, rtask = require( 'local-task' ),
                     require( 'remote-task' )
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
local get_blob = assert( farm.get_blob )
local get_blob_to_file = assert( farm.get_blob_to_file )
local log_command = assert( ccache.log_command )
local machine_id = assert( network.machine_id )
local match_compiler = assert( compilers.match_compiler )
local os_version = assert( os_stat.os_version )
local set_blob_from_file = assert( farm.set_blob_from_file )

local deep_copy = assert( tbl.deep_copy )
local info = assert( logger.info )
local debug = assert( logger.debug )

local getcwd = assert( posix.unistd.getcwd )

local format = assert( string.format )
local concat = assert( table.concat )
local remove = assert( table.remove )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
logger.level = assert( logger.levels.DEBUG )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
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

local function create_local_preprocess_task( analyzed )
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

  local output_file = format( '%s/%s.ii', o, c )
  decoded.special_flags.o = output_file
  local command = concat( cencode( decoded ), ' ' )
  log_command( debug, 'command: %s', command )
  local cwd = getcwd()

  -- FIXME: improve this
  local profile = command .. cwd .. machine_id()

  local task_hash = hash.hash( profile )
  local description = format( 'preprocess %s',
                              decoded.input_c_cpp_file )
  return {
    hash=task_hash,
    command=command,
    cwd=cwd,
    description=description,
    output_file=output_file,
  }
end

local function create_remote_compile_task( analyzed, ii_hash )
  assert( analyzed )
  assert( ii_hash )
  local decoded = deep_copy( assert( analyzed.decoded ) )
  local compiler = assert( analyzed.compiler_match )
  assert( decoded.special_flags.c )
  assert( decoded.special_flags.o )
  assert( decoded.input_c_cpp_file )
  assert( not decoded.special_flags.E )
  assert( #decoded.input_object_files == 0 )
  decoded.binary = nil
  decoded.special_flags.MD = nil
  decoded.special_flags.MMD = nil
  decoded.special_flags.MT = nil
  decoded.special_flags.MF = nil
  decoded.includes = {}
  local flags = concat( cencode( decoded ), ' ' )

  local os = assert( os_version() )
  local compiler_type = assert( compiler.compiler_type )
  local compiler_version = assert( compiler.compiler_version )
  local compiler_flags = assert( flags )
  local description = format( 'compiling %s',
                              decoded.input_c_cpp_file )
  local input = ii_hash

  -- FIXME: improve this.
  local profile = os .. compiler_type .. compiler_version ..
                      compiler_flags .. input

  local task_hash = hash.hash( profile )

  -- Create a task.
  return {
    hash=task_hash,
    os=os,
    compiler_type=compiler_type,
    compiler_version=compiler_version,
    compiler_flags=compiler_flags,
    description=description,
    input=input,
  }
end

-- TODO: dedupe this with the remote/compile version.
local function run_preprocess( cxn, analyzed )
  local task = create_local_preprocess_task( analyzed )
  ltask.delete_output( cxn, task.hash )
  local task_output = ltask.output_of( cxn, task.hash )
  if not task_output then
    ltask.post_task( cxn, task.hash, {
      command=assert( task.command ),
      cwd=assert( task.cwd ),
      description=assert( task.description ),
    } )
    info( 'queueing for task %s...', task.hash )
    task_output = ltask.queue_and_wait( cxn, task.hash )
    -- Whatever happens we need to forward the stderr of the pre-
    -- processor so that it can appear in the console.
    local task_stderr_hash = assert( task_output.stderr )
    assert( io.stderr ):write( get_blob( cxn, task_stderr_hash ) )
    local status = assert( task_output.status )
    if tonumber( status ) ~= 0 then
      error( 'preprocess command return non-zero status: ' ..
                 status )
    end
  end
  assert( task_output )
  local output_file = assert( task.output_file )
  local ii_hash = set_blob_from_file( cxn, output_file )
  return ii_hash
end

-- TODO: dedupe this with the local/preprocess version.
local function run_compile( cxn, analyzed, ii_hash )
  assert( analyzed )
  assert( ii_hash )
  local task = create_remote_compile_task( analyzed, ii_hash )
  local task_output = rtask.output_of( cxn, task.hash )
  if not task_output then
    rtask.post_task( cxn, task.hash, {
      os=assert( task.os ),
      compiler_type=assert( task.compiler_type ),
      compiler_version=assert( task.compiler_version ),
      compiler_flags=assert( task.compiler_flags ),
      input=assert( task.input ),
      description=assert( task.description ),
    } )
    info( 'queueing for task %s...', task.hash )
    task_output = rtask.queue_and_wait( cxn, task.hash )
    -- Whatever happens we need to forward the stderr of the pre-
    -- processor so that it can appear in the console.
    local task_stderr_hash = assert( task_output.stderr )
    assert( io.stderr ):write( get_blob( cxn, task_stderr_hash ) )
    local status = assert( task_output.status )
    if tonumber( status ) ~= 0 then
      error( 'compile command return non-zero status: ' .. status )
    end
  end
  assert( task_output )
  local output_hash = assert( task_output.output )
  local output_file = analyzed.decoded.special_flags.o
  assert( get_blob_to_file( cxn, output_hash, output_file ) )
  return true
end

local function run( cxn, analyzed )
  local ii_hash = assert( run_preprocess( cxn, analyzed ) )
  run_compile( cxn, analyzed, ii_hash )
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  -- Let's do this here to fail fast if we can't determine it.
  assert( os_version(), 'cannot determine os version tag' )

  local cxn<close> = assert( ru.connect() )

  local command = assert( arg )
  local analyzed = assert( analyze_command( command ) )
  run( cxn, analyzed )

  return 0
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
