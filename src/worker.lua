-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local compilers = require( 'compilers' )
local config = require( 'config' )
local decode = require( 'decode' )
local hash = require( 'hash' )
local network = require( 'network' )
local os_stat = require( 'os-stat' )
local redist = require( 'redist' )
local subprocess = require( 'subprocess' )

local file = require( 'moon.file' )
local logger = require( 'moon.logger' )
local merr = require( 'moon.err' )
local printer = require( 'moon.printer' )
local str = require( 'moon.str' )

local argparse = require( 'argparse' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local popen = assert( subprocess.popen )
local catch_control_c = assert( merr.catch_control_c )
local cdecode = assert( decode.cdecode )
local cvalidate = assert( decode.cvalidate )
local cencode = assert( decode.cencode )
local dbg = assert( logger.dbg )
local err = assert( logger.err )
local format_table = assert( printer.format_table )
local info = assert( logger.info )
local os_version = assert( os_stat.os_version )
local read_file = assert( file.read_file )
local trace = assert( logger.trace )
local write_file = assert( file.write_file )

local format = string.format
local insert = table.insert
local unpack = table.unpack
local concat = table.concat

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local HOME = assert( os.getenv( 'HOME' ),
                     'HOME environment variable not set' )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
-- Parsed CLI args will be put here.
local args

str.enable_string_injections()

local PID = assert( posix.getpid().pid )

local MACHINE_LABEL = assert( network.machine_label() )

local STATE = {
  status='idle', --
  task=nil, --
}

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function assertf( condition, ... )
  if condition then return end
  local msg = format( ... )
  assert( condition, msg )
end

local function next_task( cxn )
  local o
  local remote_queue = 'farm:compile:cpp:queue'
  local local_queue = format( 'farm:local:queue:%s',
                              MACHINE_LABEL )
  if not args.wait then
    return cxn:lpop( local_queue ) or cxn:lpop( remote_queue )
  else
    o = cxn:blpop( local_queue, remote_queue,
                   config.worker.POLL_TIMEOUT )
    return o and o[2]
  end
end

local function set_hash( cxn, key, tbl, expiry )
  assert( type( tbl ) == 'table' )
  local kvs = {}
  for k, v in pairs( tbl ) do
    insert( kvs, k )
    insert( kvs, v )
  end
  cxn:transaction( function( t )
    t:del( key )
    t:hset( key, unpack( kvs ) )
    if expiry then t:expire( key, expiry ) end
  end )
end

local function advertise( cxn )
  local key = format( 'farm:worker:%s:%s', MACHINE_LABEL, PID )
  set_hash( cxn, key, {
    status=STATE.status, --
    task=STATE.task or 'none', --
  }, config.worker.EXPIRE_ADVERTISE )
end

local function find_task( cxn, task_hash )
  dbg( 'looking up task: %s', task_hash )
  local key =
      format( 'farm:compile:cpp:task:%s:input', task_hash )
  return cxn:hgetall( key )
end

local function find_input( cxn, input_hash )
  dbg( 'finding blob: %s', input_hash )
  local key = format( 'farm:blob:%s', input_hash )
  local blob = cxn:get( key )
  assert( type( blob ) == 'string', 'unexpected blob type' )
  return blob
end

local function find_compiler( compiler_type, compiler_version )
  local compiler = assert( compilers.locate( {
    user_home=HOME, --
    compiler_type=compiler_type, --
    compiler_version=compiler_version, --
  } ) )
  dbg( 'constructed compiler %s', compiler )
  return compiler
end

local function compile( cxn, task_hash, compiler, flags, body )
  local tmp_input = format( '%s/farm.task.compiler.%s.cpp',
                            args.workarea, task_hash )
  local tmp_output = format( '%s/farm.task.compiler.%s.o',
                             args.workarea, task_hash )
  local full_str = format( '%s %s', compiler, flags )
  local compile_info = assert( cdecode( full_str ) )
  cvalidate( compile_info )
  assert( compile_info.binary )
  assert( not compile_info.special_flags.E,
          'workers should not be doing preprocessing' )
  assert( not compile_info.special_flags.c,
          '-c must be stripped from compile command' )
  assert( not compile_info.special_flags.o,
          '-o must be stripped from compile command' )
  compile_info.binary = nil -- will insert manually below.
  compile_info.special_flags.c = tmp_input
  compile_info.special_flags.o = tmp_output
  local cmd_args = assert( cencode( compile_info ) )
  dbg( 'running: %s %s', compiler, concat( cmd_args, ' ' ) )
  local polls = 0
  local poll_interval_millis = 100
  local function on_poll()
    advertise( cxn )
    dbg( 'waiting for compilation: %.1fs',
         (polls * poll_interval_millis) / 1000 )
    polls = polls + 1
    -- if polls > 10 then return CANCEL_PROCESS end
    if polls > 10 * 60 * 10 then -- 10 mins (given poll interval)
      return error( 'compilation timed out' )
    end
  end
  local opts = {
    use_path_env=true,
    poll_timeout_millis=poll_interval_millis,
    on_poll=on_poll,
  }
  write_file( tmp_input, body )
  local status, stdout, stderr, reason =
      popen( compiler, cmd_args, opts )
  if reason == 'cancelled' then
    err( 'compilation cancelled: %s', reason )
    return { status=1, stdout=stdout, stderr=stderr }
  end
  local output = (status == 0) and read_file( tmp_output ) or ''
  return {
    status=status,
    output=output,
    stdout=stdout,
    stderr=stderr,
  }
end

local function add_blob( cxn, body )
  assert( body, 'invalid body' )
  local h = hash.hash( body )
  local key = format( 'farm:blob:%s', h )
  if not cxn:exists( key ) then cxn:set( key, body ) end
  return h
end

local function publish( cxn, task_hash, event )
  assert( task_hash )
  assert( event )
  local pub_key = format( 'farm:compile:cpp:events' )
  cxn:publish( pub_key, format( '%s:%s', task_hash, event ) )
end

local function perform_task( cxn, task_hash )
  info( 'performing task: %s', task_hash )
  publish( cxn, task_hash, 'started' )
  STATE.status = 'compiling'
  STATE.task = task_hash
  local task_info = find_task( cxn, task_hash )
  assertf( task_info.input, 'cannot find task: %s', task_hash )
  local input_hash = assert( task_info.input )
  local body = find_input( cxn, input_hash )
  assertf( body, 'cannot find body for input %s', input_hash )
  dbg( 'body is %d bytes', #body )
  local compiler = find_compiler( task_info.compiler_type,
                                  task_info.compiler_version )
  assertf( compiler, 'cannot find compiler for task: %s',
           format_table( task_info ) )
  info( 'task description: %s', task_info.description )
  local compile_output = assert(
                             compile( cxn, task_hash, compiler,
                                      task_info.compiler_flags,
                                      body ) )
  if compile_output.status == 0 then
    info( 'compilation successful' )
  else
    err( 'compile failed [status=%d]:', compile_output.status )
    print( compile_output.stderr )
  end
  return compile_output
end

local function set_result( cxn, task_hash, result )
  local out_key = format( 'farm:compile:cpp:task:%s:output',
                          task_hash )
  local function to_blob( content )
    return add_blob( cxn, content )
  end
  cxn:del( out_key )
  set_hash( cxn, out_key, {
    status=assert( result.status ),
    output=to_blob( result.output ),
    stdout=to_blob( result.stdout ),
    stderr=to_blob( result.stderr ),
  } )
  publish( cxn, task_hash, 'finished' )
end

local function process_next_task( cxn )
  local task_hash
  repeat
    STATE.status = 'idle'
    STATE.task = nil
    advertise( cxn )
    trace( 'checking for task...' )
    task_hash = next_task( cxn )
    if not task_hash and not args.wait then return false end
  until task_hash
  dbg( 'found task hash: %s', task_hash )
  local ok, result = pcall( perform_task, cxn, task_hash )
  if ok then
    local compile_result = result
    set_result( cxn, task_hash, compile_result )
  else
    local reason = tostring( result ) or 'unknown error'
    err( '%s', reason )
    local task_result = {
      status=1,
      output='',
      stdout='',
      stderr=reason,
    }
    set_result( cxn, task_hash, task_result )
  end
  return true
end

local function ping( cxn )
  assert( cxn:ping(), 'lost connection to redis server' )
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local parser = argparse( arg[0],
                           'ReDist Distributed Build Worker' )

  -- LuaFormatter off
  parser:option( '--verbosity' )
        :choices{ 'error', 'warning', 'info', 'debug', 'trace' }
        :default( 'warning' )
        :description( 'log level' )

  parser:option( '--workarea' )
        :default( '/tmp' )
        :description( 'where temporary files are stored' )

  parser:option( '-m --mode' )
        :choices{ 'one', 'drain' }
        :default( 'one' )
        :description( 'how many tasks to process' )

  parser:flag( '-w --wait' )
        :default( false )
        :description( 'whether to wait for new tasks' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  -- Let's do this here to fail fast if we can't determine it.
  assert( os_version(), 'cannot determine os version tag' )

  local cxn = assert( redist.connect() )

  while process_next_task( cxn ) and args.mode == 'drain' do
    ping( cxn )
  end
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( catch_control_c( main, function()
  print( '\nctrl-c: exiting.' )
  return 127
end ) )