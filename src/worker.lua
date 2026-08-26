-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local ccache = require( 'ccache-helper' )
local compilers = require( 'compilers' )
local config = require( 'config' )
local decode = require( 'decode' )
local farm = require( 'farm' )
-- TODO: consolidate these two modules.
local ltask, rtask = require( 'local-task' ),
                     require( 'remote-task' )
local network = require( 'network' )
local os_stat = require( 'os-stat' )
local ru = require( 'redis-util' )
local subprocess = require( 'subprocess' )
local workarea = require( 'workarea' )

local mcleanup = require( 'moon.cleanup' )
local file = require( 'moon.file' )
local logger = require( 'moon.logger' )
local merr = require( 'moon.err' )
local printer = require( 'moon.printer' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )

local argparse = require( 'argparse' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local assertf = assert( merr.assertf )
local catch_control_c = assert( merr.catch_control_c )
local cencode = assert( decode.cencode )
local cleanup = assert( mcleanup.cleanup )
local cround_trip = assert( decode.cround_trip )
local debug = assert( logger.debug )
local err = assert( logger.err )
local format_table = assert( printer.format_table )
local download_blob = assert( farm.download_blob )
local info = assert( logger.info )
local log_command = assert( ccache.log_command )
local machine_label = assert( network.machine_label )
local match_compiler = assert( compilers.match_compiler )
local now_seconds = assert( time.now_seconds )
local timeit = assert( time.timeit_micros )
local os_version = assert( os_stat.os_version )
local popen = assert( subprocess.popen )
local read_file = assert( file.read_file )
local remove_when_done = assert( workarea.remove_when_done )
local set_hash = assert( ru.set_hash )
local trace = assert( logger.trace )
local write_file = assert( file.write_file )

local format = assert( string.format )
local insert = assert( table.insert )
local concat = assert( table.concat )
local remove = assert( table.remove )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local HOME = assert( os.getenv( 'HOME' ),
                     'HOME environment variable not set' )

local CANCEL_PROCESS = assert( subprocess.CANCEL_PROCESS )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
-- Parsed CLI args will be put here.
local args

str.enable_string_injections()

local PID = assert( posix.getpid().pid )

local STATE = {
  status='idle', --
  last_advertise=0, --
  task=nil, --
}

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function next_task( cxn )
  local timeout = config.worker.QUEUE_POLL_TIMEOUT_SECS
  local remote_queue = 'farm:compile:cpp:queue'
  local local_queue = format( 'farm:local:queue:%s',
                              machine_label() )
  local function result( key, task )
    assert( key, 'task queue key is nil' )
    assert( task, 'task is nil' )
    if key == local_queue then
      cxn:rpush( 'farm:log:queues', format(
                     'node %s popped local task %s',
                     machine_label(), task ) )
      return { type='local', hash=task }
    end
    if key == remote_queue then
      cxn:rpush( 'farm:log:queues', format(
                     'node %s popped remote task %s',
                     machine_label(), task ) )
      return { type='remote', hash=task }
    end
    error( 'popped from unexpected key: ' .. key )
  end
  local o
  if not args.wait then
    if args.listen == 'local' or args.listen == 'both' then
      o = cxn:lpop( local_queue )
      if o then return result( local_queue, o ) end
    end
    if args.listen == 'remote' or args.listen == 'both' then
      o = cxn:lpop( remote_queue )
      if o then return result( remote_queue, o ) end
    end
  else
    if args.listen == 'local' then
      o = cxn:blpop( local_queue, timeout )
    elseif args.listen == 'remote' then
      o = cxn:blpop( remote_queue, timeout )
    else
      -- Local queue must come first.
      o = cxn:blpop( local_queue, remote_queue, timeout )
    end
    return o and result( o[1], o[2] )
  end
end

local function advertise( cxn )
  if not args.advertise then return end
  local now = now_seconds()
  if now < STATE.last_advertise +
      config.worker.ADVERTISE_INTERVAL_SECS then return end
  STATE.last_advertise = now
  local key = format( 'farm:worker:%s:%s', machine_label(), PID )
  local sock = assert( cxn.network.socket )
  local ip, port, _ = sock:getsockname()
  local worker = {
    status=STATE.status,
    from=format( '%s:%s', ip, port ),
    last_advertise=STATE.last_advertise,
    listen=assert( args.listen ),
    task=STATE.task or 'none',
  }
  trace( 'advertising %s:%s: %s', machine_label(), PID,
         format_table( worker ) )
  set_hash( cxn, key, worker, config.worker.EXPIRE_ADVERTISE_SECS )
end

local function unadvertise( cxn )
  if not args.advertise then return end
  debug( 'unadvertising %s:%s', machine_label(), PID )
  local key = format( 'farm:worker:%s:%s', machine_label(), PID )
  cxn:del( key )
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

local function make_poller( cxn, desc )
  local start = now_seconds()
  local function on_poll()
    advertise( cxn ) -- does its own throttling.
    local now = now_seconds()
    local waited = now - start
    debug( 'waiting for %s: %.1fs', desc, waited )
    if waited > config.worker.POPEN_TIMEOUT_SECS then
      return CANCEL_PROCESS
    end
  end
  return on_poll
end

local function compile(cxn, task_hash, compiler, compiler_type,
                       flags, body )
  local pp_style = compilers.pp_style( compiler_type )
  local ext = assert( pp_style.ext )
  local tmp_input = format( '%s/farm.task.compiler.%s.cpp%s',
                            args.workarea, task_hash, ext )
  local tmp_output = format( '%s/farm.task.compiler.%s.o',
                             args.workarea, task_hash )
  local _<close> = remove_when_done( tmp_input )
  local _<close> = remove_when_done( tmp_output )
  local cmd_elems = { compiler }
  for _, flag in ipairs( flags:words() ) do
    insert( cmd_elems, flag )
  end
  local compile_info = assert( cround_trip( cmd_elems ) )
  assert( compile_info.binary )
  assert( not compile_info.special_flags.E,
          'workers should not be doing preprocessing' )
  assert( compile_info.special_flags.c,
          '-c must be present in compile command' )
  assert( compile_info.special_flags.o,
          '-o must be present in compile command' )
  compile_info.binary = nil -- will insert manually below.
  compile_info.special_flags.c = true
  compile_info.special_flags.x = assert( pp_style.x_compile )
  compile_info.input_c_cpp_file = tmp_input
  compile_info.special_flags.o = tmp_output
  local cmd_args = assert( cencode( compile_info ) )
  debug( 'running: %s %s', compiler, concat( cmd_args, ' ' ) )
  local opts = {
    use_path_env=false,
    poll_timeout_millis=config.worker.POPEN_POLL_TIMEOUT_MILLIS,
    on_poll=assert( make_poller( cxn, 'compilation' ) ),
    cwd=nil,
  }
  write_file( tmp_input, body )
  local time_taken, ran = timeit( function()
    return popen( compiler, cmd_args, opts )
  end )
  if ran.reason == 'cancelled' then
    err( 'compilation cancelled: %s', ran.reason )
    return { status=1, stdout=ran.stdout, stderr=ran.stderr }
  end
  local output = (ran.status == 0) and read_file( tmp_output ) or
                     ''
  return {
    status=ran.status,
    output=output,
    stdout=ran.stdout,
    stderr=ran.stderr,
    time_micros=time_taken,
  }
end

local function run_remote_task( cxn, task_hash )
  info( 'performing remote task: %s', task_hash )
  STATE.status = 'compiling'
  STATE.task = task_hash
  local task_info = rtask.find( cxn, task_hash )
  assertf( task_info.input, 'cannot find remote task: %s',
           task_hash )
  local input_hash = assert( task_info.input )
  local body = download_blob( cxn, input_hash )
  assertf( body, 'cannot find body for input %s', input_hash )
  debug( 'body is %d bytes', #body )
  local compiler = find_compiler( task_info.compiler_type,
                                  task_info.compiler_version )
  assertf( compiler, 'cannot find compiler for task: %s',
           format_table( task_info ) )
  info( 'task description: %s', task_info.description )
  local compile_output = assert(
                             compile( cxn, task_hash, compiler,
                                      task_info.compiler_type,
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
  STATE.status = 'preprocessing'
  STATE.task = task_hash
  local task_info = ltask.find( cxn, task_hash )
  assertf( task_info.command, 'cannot find local task: %s',
           task_hash )
  local command_line = assert( task_info.command )
  log_command( trace, '%s', command_line )
  local cwd =
      assert( task_info.cwd, 'missing cwd in local task' )
  debug( 'cd %s', cwd )
  -- Sanity check. We technically don't need to know what command
  -- we're running here, but we should validate it just to be
  -- safe.
  local decoded = cround_trip( command_line:words() )
  assert( decoded.special_flags.E,
          'expected preprocessor command' )
  assert( match_compiler( decoded.binary ) )
  local cmd_args = command_line:words()
  local command = cmd_args[1]
  remove( cmd_args, 1 )
  local opts = {
    use_path_env=false,
    poll_timeout_millis=config.worker.POPEN_POLL_TIMEOUT_MILLIS,
    on_poll=assert( make_poller( cxn, 'command' ) ),
    cwd=cwd,
  }
  local time_taken, ran = timeit( function()
    return popen( command, cmd_args, opts )
  end )
  if ran.status == 0 then
    info( 'command successful' )
    if #ran.stdout > 0 then trace( 'stdout:\n%s', ran.stdout ) end
  else
    err( 'command failed [status=%d]:', ran.status )
    err( 'exit reason:', tostring( ran.reason ) )
  end
  return {
    status=ran.status,
    stdout=ran.stdout,
    stderr=ran.stderr,
    time_micros=time_taken,
  }
end

local function process_task(cxn, task, perform, set_result,
                            publish )
  assert( perform )
  assert( set_result )
  local task_hash = assert( task.hash )
  debug( 'found task hash: %s', task_hash )
  local approx_active_key = format(
                                'farm:worker:%s:approximate_active',
                                machine_label() )
  cxn:incr( approx_active_key )
  cxn:expire( approx_active_key,
              config.worker.EXPIRE_APPROX_ACTIVE_SECS )
  local update_active<close> = cleanup( function()
    cxn:decr( approx_active_key )
  end )
  -- Publish after we increment the active count.
  publish( cxn, task_hash, 'started' )
  local ok, result = pcall( perform, cxn, task_hash )
  update_active:cleanup_now()
  if ok then
    set_result( cxn, task_hash, result )
    if result.status == 0 then
      publish( cxn, task_hash, 'finished:success' )
    else
      publish( cxn, task_hash,
               format( 'finished:error:%d', result.status ) )
    end
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
      time_micros='',
    }
    set_result( cxn, task_hash, task_result )
    publish( cxn, task_hash, 'finished:failed-to-run' )
    if args.fail_on_meta_error then
      error( 'fail-on-meta-error: exiting' )
    end
  end
end

local function process_next_task( cxn )
  local task
  repeat
    STATE.status = 'idle'
    STATE.task = nil
    advertise( cxn ) -- does its own throttling.
    trace( 'checking for task...' )
    task = next_task( cxn )
    if not task and not args.wait then return false end
  until task
  assert( task.type )
  if task.type == 'local' then
    process_task( cxn, task, run_local_task, ltask.set_result,
                  ltask.publish_event )
  elseif task.type == 'remote' then
    process_task( cxn, task, run_remote_task, rtask.set_result,
                  rtask.publish_event )
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

  parser:option( '--listen' )
        :choices{ 'local', 'remote', 'both' }
        :default( 'both' )
        :description( 'whether to listen for local or remote tasks' )

  parser:flag( '-w --wait' )
        :default( false )
        :description( 'whether to wait for new tasks' )

  parser:flag( '--fail-on-meta-error' )
        :default( false )
        :description( 'exit when an error happens that prevents a command from running at all' )

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

  local cxn<close> = assert( ru.connect() )

  info( 'listen: %s', args.listen )

  local _<close> = cleanup( function() unadvertise( cxn ) end )

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