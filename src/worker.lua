-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local redist = require( 'redist' )
local subprocess = require( 'subprocess' )
local hash = require( 'hash' )

local printer = require( 'moon.printer' )
local logger = require( 'moon.logger' )
local time = require( 'moon.time' )
local list = require( 'moon.list' )
local file = require( 'moon.file' )

local posix = require( 'posix' )
local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local popen = assert( subprocess.popen )

local format_table = assert( printer.format_table )
local info = assert( logger.info )
local dbg = assert( logger.dbg )
local err = assert( logger.err )
local sleep = assert( time.sleep )
local split = assert( list.split )
local read_file = assert( file.read_file )
local write_file = assert( file.write_file )

local dns = assert( socket.dns )

local format = string.format
local insert = table.insert
local unpack = table.unpack
local concat = table.concat

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local POLL_TIMEOUT = 1
local EXPIRE_ADVERTISE = 5

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
logger.level = logger.levels.DEBUG
-- logger.level = logger.levels.INFO

string.split = split

local PID = assert( posix.getpid().pid )

local HOSTNAME = assert( dns.gethostname() )

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
  local o = cxn:blpop( 'farm:compile:cpp:queue', POLL_TIMEOUT )
  if not o then return end
  assert( o[2], 'invalid task' )
  return o[2]
end

local function set_hash( cxn, key, tbl, expiry )
  assert( type( tbl ) == 'table' )
  local args = {}
  for k, v in pairs( tbl ) do
    insert( args, k )
    insert( args, v )
  end
  cxn:transaction( function( t )
    t:del( key )
    t:hset( key, unpack( args ) )
    if expiry then t:expire( key, expiry ) end
  end )
end

local function advertise( cxn )
  local key = format( 'farm:worker:%s:%s', HOSTNAME, PID )
  set_hash( cxn, key, {
    hostname=HOSTNAME, --
    pid=PID, --
    status=STATE.status, --
    task=STATE.task, --
  }, EXPIRE_ADVERTISE )
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
  local compiler
  if compiler_type == 'llvm' then
    local home = '/home/dsicilia'
    compiler = format( '%s/dev/tools/llvm-pgo-%s/bin/clang++',
                       home, compiler_version )
  elseif compiler_type == 'gcc' then
    compiler = 'g++'
  else
    error( 'unrecognized compiler type: %s', compiler_type )
  end
  dbg( 'constructed compiler %s', compiler )
  return compiler
end

local function compile( cxn, task_hash, compiler, flags, body )
  local tmpdir = '/tmp'
  local tmp_input = format( '%s/farm.task.compiler.%s.cpp',
                            tmpdir, task_hash )
  local tmp_output = format( '%s/farm.task.compiler.%s.o',
                             tmpdir, task_hash )
  local args = flags:split( '%s+' )
  local function arg( what ) insert( args, what ) end
  -- arg( '-fcolor-diagnostics' )
  arg( '-fdiagnostics-color' )
  arg( '-c' )
  arg( tmp_input )
  arg( '-o' )
  arg( tmp_output )
  dbg( 'running: %s', concat( args, ' ' ) )
  local polls = 0
  local poll_interval_millis = 200
  local function on_poll()
    advertise( cxn )
    dbg( 'waiting for compilation: %.1fs',
         (polls * poll_interval_millis) / 1000 )
    polls = polls + 1
    -- if polls > 10 then return CANCEL_PROCESS end
    if polls > 10 then return error( 'compilation timed out' ) end
  end
  local opts = {
    use_path_env=true,
    poll_timeout_millis=poll_interval_millis,
    on_poll=on_poll,
  }
  write_file( tmp_input, body )
  local status, stdout, stderr, reason =
      popen( compiler, args, opts )
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

local function perform_task( cxn, task_hash )
  info( 'performing task: %s', task_hash )
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
  info( 'compiling %s', task_info.description )
  local compiled = assert( compile( cxn, task_hash, compiler,
                                    task_info.compiler_flags,
                                    body ) )
  if compiled.status == 0 then
    info( 'compilation successful' )
  else
    err( 'compile failed [status=%d]:', compiled.status )
    print( compiled.stderr )
  end
  -- local output_hash = hash.hash( compiled.output )
  local out_key = format( 'farm:compile:cpp:task:%s:output',
                          task_hash )
  local function to_blob( content )
    return add_blob( cxn, content )
  end
  cxn:del( out_key )
  set_hash( cxn, out_key, {
    status=compiled.status,
    output=to_blob( compiled.output ),
    stdout=to_blob( compiled.stdout ),
    stderr=to_blob( compiled.stderr ),
  } )
end

local function process_next_task( cxn )
  while true do
    STATE.status = 'idle'
    STATE.task = nil
    advertise( cxn )
    -- dbg( 'waiting for task...' )
    local ok, res = pcall( next_task, cxn )
    if not ok and res and res:match( 'interrupted' ) then
      print( '\nexiting.' )
      os.exit( 0 )
    end
    local task_hash = res
    if not task_hash then goto continue end
    dbg( 'found task hash: %s', task_hash )
    ok, res = pcall( perform_task, cxn, task_hash )
    if ok then break end
    err( '%s', res )
    ::continue::
  end
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main( ... )
  local args = { ... }
  local arg1 = args[1]
  local watch = (arg1 == '--watch')

  local cxn = assert( redist.connect() )
  repeat process_next_task( cxn ) until not watch
end

-----------------------------------------------------------------
-- Launch.
-----------------------------------------------------------------
os.exit( main( ... ) )