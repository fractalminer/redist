-- ReDist Builder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local ccache = require( 'ccache-helper' )
local compilers = require( 'compilers' )
local decode = require( 'decode' )
local farm = require( 'farm' )
local mhash = require( 'hash' )
-- TODO: consolidate these two modules.
local ltask, rtask = require( 'local-task' ),
                     require( 'remote-task' )
local network = require( 'network' )
local os_stat = require( 'os-stat' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local str = require( 'moon.str' )
local tbl = require( 'moon.tbl' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local blob_exists = assert( farm.blob_exists )
local cencode = assert( decode.cencode )
local cround_trip = assert( decode.cround_trip )
local download_blob = assert( farm.download_blob )
local download_blob_to_file =
    assert( farm.download_blob_to_file )
local hash = assert( mhash.hash )
local log_command = assert( ccache.log_command )
local machine_id = assert( network.machine_id )
local match_compiler = assert( compilers.match_compiler )
local os_version = assert( os_stat.os_version )
local set_blob_from_file = assert( farm.set_blob_from_file )

local deep_copy = assert( tbl.deep_copy )
local err = assert( logger.err )
local info = assert( logger.info )
local debug = assert( logger.debug )
local unwords = assert( str.unwords )

local getcwd = assert( posix.unistd.getcwd )
local dirname = assert( posix.libgen.dirname )
local basename = assert( posix.libgen.basename )

local format = assert( string.format )
local insert = assert( table.insert )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
logger.level = assert( logger.levels.WARNING )

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
  assert( decoded.special_flags.c )
  assert( decoded.special_flags.o )
  assert( decoded.input_c_cpp_file )
  assert( not decoded.special_flags.E )
  decoded.special_flags.c = false
  decoded.special_flags.E = true
  local pp_style = compilers.pp_style(
                       analyzed.compiler_match.compiler_type )
  for _, flag in ipairs( pp_style.pp_flags ) do
    insert( decoded.flags, flag )
  end
  local cfname = basename( assert( decoded.input_c_cpp_file ) )
  local out_dir = dirname( assert( decoded.special_flags.o ) )
  local ext = assert( pp_style.ext )
  local output_file = format( '%s/%s%s', out_dir, cfname, ext )
  decoded.special_flags.o = output_file
  decoded.special_flags.x = assert( pp_style.x_pp )
  local command = unwords( cencode( decoded ) )
  log_command( debug, 'command: %s', command )
  local cwd = getcwd()

  -- This doesn't have to be perfect because the preprocessing
  -- tasks are always rerun (redis-cached results are never
  -- used). This is because then we'd have to hash the source
  -- file and all headers it depends on, which we don't want to
  -- be in the business of doing here.
  local task_hash = hash{
    os_version(), --
    command, --
    cwd, --
    machine_id(), --
  }

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
  -- NOTE: Although we can get rid of the include directives
  -- here, for -D (define) directives, we may need to preserve
  -- those since our preprocess might be an include-only pre-
  -- process that leaves the macros in place (-frewrite-includes)
  -- which we use for clang. See the comments around the pp_style
  -- method for more info.
  decoded.includes = {}
  local flags = unwords( cencode( decoded ) )

  local os = assert( os_version() )
  local compiler_type = assert( compiler.compiler_type )
  local compiler_version = assert( compiler.compiler_version )
  local compiler_flags = assert( flags )
  local description = format( 'compiling %s',
                              decoded.input_c_cpp_file )
  -- Ideally we'd include the source itself in the hash instead
  -- of hashing the hash, but this is probably good enough and it
  -- will save some CPU.
  local input = ii_hash

  -- NOTE: When we invoke clang we often uses the libstdc++ in
  -- gcc-current, which is a symlink that could in theory point
  -- to different gcc versions on different hosts. However, we
  -- don't need to worry about that here because this file has
  -- already been preprocessed (at least with respect to in-
  -- cludes) and so it is a fully standalone file that will not
  -- pull in any headers or libraries, it is just a compilation.
  -- And preprocessing happens on the build host and so the cor-
  -- rect stdlib version will already have been guaranteed.
  local task_hash = hash{
    os, --
    compiler_type, --
    compiler_version, --
    compiler_flags, --
    input, --
  }

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

local function run_preprocess( cxn, analyzed )
  local task = create_local_preprocess_task( analyzed )
  ltask.delete_output( cxn, task.hash )
  ltask.post_task( cxn, task.hash, {
    command=assert( task.command ),
    cwd=assert( task.cwd ),
    description=assert( task.description ),
  } )
  info( 'queueing for task %s...', task.hash )
  local task_output = ltask.queue_and_wait( cxn, task.hash )
  -- Whatever happens we need to forward the stderr of the pre-
  -- processor so that it can appear in the console.
  local task_stderr_hash = assert( task_output.stderr )
  assert( io.stderr ):write(
      download_blob( cxn, task_stderr_hash ) )
  local status = assert( task_output.status )
  if tonumber( status ) ~= 0 then
    err( 'preprocess command return non-zero status: %s', status )
    return nil
  end
  local output_file = assert( task.output_file )
  local ii_hash = set_blob_from_file( cxn, output_file )
  return ii_hash
end

local function run_compile( cxn, analyzed, ii_hash )
  assert( analyzed )
  assert( ii_hash )
  local task = create_remote_compile_task( analyzed, ii_hash )
  local task_output = rtask.output_of( cxn, task.hash )
  if not task_output or
      not blob_exists( cxn, task_output.stderr ) or
      not blob_exists( cxn, task_output.output ) then
    rtask.delete_output( cxn, task.hash )
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
    assert( io.stderr ):write( download_blob( cxn,
                                              task_stderr_hash ) )
    local status = assert( task_output.status )
    if tonumber( status ) ~= 0 then
      err( 'compile command returned non-zero status: %s', status )
      return false
    end
    assert( blob_exists( cxn, task_output.output ), format(
                'blob does not exist for %s', task_output.output ) )
  else
    assert( task_output )
    assert( blob_exists( cxn, task_output.output ) )
  end
  assert( task_output )
  local status = assert( task_output.status )
  if tonumber( status ) ~= 0 then
    err( 'compile command returned non-zero status: %s', status )
    return false
  end
  local output_hash = assert( task_output.output )
  local output_file = analyzed.decoded.special_flags.o
  assert( download_blob_to_file( cxn, output_hash, output_file ) )
  return true
end

local function run( cxn, analyzed )
  local ii_hash = assert( run_preprocess( cxn, analyzed ) )
  if not ii_hash then return false end
  return run_compile( cxn, analyzed, ii_hash )
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
  local ok = run( cxn, analyzed )
  if ok then return 0 end
  return 1
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
