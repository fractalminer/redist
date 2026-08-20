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
local catch_control_c = assert( merr.catch_control_c )
local cdecode = assert( decode.cdecode )
local cencode = assert( decode.cencode )
local match_compiler = assert( compilers.match_compiler )
local cvalidate = assert( decode.cvalidate )
local debug = assert( logger.debug )
local err = assert( logger.err )
local format_table = assert( printer.format_table )
local info = assert( logger.info )
local machine_label = assert( network.machine_label )
local os_version = assert( os_stat.os_version )
local popen = assert( subprocess.popen )
local read_file = assert( file.read_file )
local trace = assert( logger.trace )
local write_file = assert( file.write_file )

local format = string.format
local insert = table.insert
local unpack = table.unpack
local concat = table.concat
local remove = table.remove

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
  local remote_queue = 'farm:compile:cpp:queue'
  local local_queue = format( 'farm:local:queue:%s',
                              machine_label() )
  local function result( key, task )
    assert( key, 'task queue key is nil' )
    assert( task, 'task is nil' )
    if key == local_queue then
      return { type='local', hash=task }
    end
    if key == remote_queue then
      return { type='remote', hash=task }
    end
    error( 'popped from unexpected key: ' .. key )
  end
  local o
  if not args.wait then
    o = cxn:lpop( local_queue )
    if o then return result( local_queue, o ) end
    o = cxn:lpop( remote_queue )
    if o then return result( remote_queue, o ) end
  else
    -- Local queue must come first.
    o = cxn:blpop( local_queue, remote_queue,
                   config.worker.POLL_TIMEOUT )
    return o and result( o[1], o[2] )
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
  if not args.advertise then return end
  local key = format( 'farm:worker:%s:%s', machine_label(), PID )
  set_hash( cxn, key, {
    status=STATE.status, --
    task=STATE.task or 'none', --
  }, config.worker.EXPIRE_ADVERTISE )
end

local function find_remote_task( cxn, task_hash )
  debug( 'looking up remote task: %s', task_hash )
  local key =
      format( 'farm:compile:cpp:task:%s:input', task_hash )
  return cxn:hgetall( key )
end

local function find_local_task( cxn, task_hash )
  debug( 'looking up local task: %s', task_hash )
  local key = format( 'farm:local:task:%s:input', task_hash )
  return cxn:hgetall( key )
end

local function find_input( cxn, input_hash )
  debug( 'finding blob: %s', input_hash )
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
  debug( 'constructed compiler %s', compiler )
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
  debug( 'running: %s %s', compiler, concat( cmd_args, ' ' ) )
  local polls = 0
  local poll_interval_millis = 100
  local function on_poll()
    advertise( cxn )
    debug( 'waiting for compilation: %.1fs',
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

local function publish_event( cxn, key, event )
  assert( key )
  assert( event )
  cxn:publish( key, event )
end

local function publish_remote_task_event( cxn, task_hash, event )
  assert( task_hash )
  assert( event )
  local key = format( 'farm:compile:cpp:events' )
  event = format( '%s:%s', task_hash, event )
  publish_event( cxn, key, event )
end

local function publish_local_task_event( cxn, task_hash, event )
  assert( task_hash )
  assert( event )
  local key = format( 'farm:local:task:events' )
  event = format( '%s:%s', task_hash, event )
  publish_event( cxn, key, event )
end

local function run_remote_task( cxn, task_hash )
  info( 'performing remote task: %s', task_hash )
  publish_remote_task_event( cxn, task_hash, 'started' )
  STATE.status = 'compiling'
  STATE.task = task_hash
  local task_info = find_remote_task( cxn, task_hash )
  assertf( task_info.input, 'cannot find remote task: %s',
           task_hash )
  local input_hash = assert( task_info.input )
  local body = find_input( cxn, input_hash )
  assertf( body, 'cannot find body for input %s', input_hash )
  debug( 'body is %d bytes', #body )
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
    if #compile_output.stdout > 0 then
      debug( 'stdout:\n%s', compile_output.stdout )
    end
  else
    err( 'compile failed [status=%d]:', compile_output.status )
    assert( io.stdout ):write( compile_output.stdout )
    assert( io.stderr ):write( compile_output.stderr )
  end
  return compile_output
end

local function run_local_task( cxn, task_hash )
  info( 'performing local task: %s', task_hash )
  publish_local_task_event( cxn, task_hash, 'started' )
  STATE.status = 'running-local'
  STATE.task = task_hash
  local task_info = find_local_task( cxn, task_hash )
  assertf( task_info.command, 'cannot find local task: %s',
           task_hash )
  local command_line = assert( task_info.command )
  info( 'running command: %s', command_line )
  -- Sanity check. We technically don't need to know what command
  -- we're running here, but we should validate it just to be
  -- safe.
  local decoded = cdecode( command_line )
  assert( decoded.special_flags.E,
          'expected preprocessor command' )
  cvalidate( decoded )
  assert( match_compiler( decoded.binary ) )
  local cmd_args = command_line:split( '%s+' )
  local command = cmd_args[1]
  remove( cmd_args, 1 )
  local polls = 0
  local poll_interval_millis = 100
  local function on_poll()
    advertise( cxn )
    debug( 'waiting for command: %.1fs',
           (polls * poll_interval_millis) / 1000 )
    polls = polls + 1
    -- if polls > 10 then return CANCEL_PROCESS end
    if polls > 10 * 60 * 10 then -- 10 mins (given poll interval)
      return error( 'command timed out' )
    end
  end
  local opts = {
    use_path_env=true,
    poll_timeout_millis=poll_interval_millis,
    on_poll=on_poll,
  }
  local status, stdout, stderr, reason = popen( command,
                                                cmd_args, opts )
  if status == 0 then
    info( 'command successful' )
    if #stdout > 0 then trace( 'stdout:\n%s', stdout ) end
  else
    err( 'command failed [status=%d]:', status )
    err( 'exit reason:', tostring( reason ) )
    assert( io.stdout ):write( stdout )
    assert( io.stderr ):write( stderr )
  end
  return { status=status, stdout=stdout, stderr=stderr }
end

local function set_remote_result( cxn, task_hash, result )
  local out_key = format( 'farm:compile:cpp:task:%s:output',
                          task_hash )
  local function to_blob( content )
    return add_blob( cxn, content )
  end
  set_hash( cxn, out_key, {
    status=assert( result.status ),
    output=to_blob( result.output ),
    stdout=to_blob( result.stdout ),
    stderr=to_blob( result.stderr ),
  } )
  publish_remote_task_event( cxn, task_hash, 'finished' )
end

local function set_local_result( cxn, task_hash, result )
  local out_key =
      format( 'farm:local:task:%s:output', task_hash )
  local function to_blob( content )
    return add_blob( cxn, content )
  end
  set_hash( cxn, out_key, {
    status=assert( result.status ),
    stdout=to_blob( result.stdout ),
    stderr=to_blob( result.stderr ),
  } )
  publish_local_task_event( cxn, task_hash, 'finished' )
end

local function process_task( cxn, task, perform, set_result )
  assert( perform )
  assert( set_result )
  local task_hash = assert( task.hash )
  debug( 'found task hash: %s', task_hash )
  local ok, result = pcall( perform, cxn, task_hash )
  if ok then
    set_result( cxn, task_hash, result )
  else
    local reason = tostring( result ) or 'unknown error'
    err( '%s', reason )
    -- In this case we threw an error while trying to execute the
    -- task so we don't even have the stdout/stderr of the task
    -- as it may not have even run at all. If it did run but just
    -- returned an error code then the 'ok' branch should actu-
    -- ally handle that.
    local task_result = {
      status=1,
      output='',
      stdout='',
      stderr=reason,
    }
    set_result( cxn, task_hash, task_result )
  end
end

local function process_next_task( cxn )
  local task
  repeat
    STATE.status = 'idle'
    STATE.task = nil
    advertise( cxn )
    trace( 'checking for task...' )
    task = next_task( cxn )
    if not task and not args.wait then return false end
  until task
  assert( task.type )
  if task.type == 'local' then
    process_task( cxn, task, run_local_task, set_local_result )
  elseif task.type == 'remote' then
    process_task( cxn, task, run_remote_task, set_remote_result )
  else
    err( 'unrecognized task type: ' .. task.type )
    return false
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

  parser:option( '--advertise' )
        :choices{ 'false', 'true' }
        :default( true )
        :convert( function( o ) return o == 'true'  end )
        :description( 'whether to continously advertise this worker' )
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