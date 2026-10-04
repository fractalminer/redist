-----------------------------------------------------------------
-- Distributes tasks.
-----------------------------------------------------------------
local cluster = require( 'cluster' )
local config = require( 'config' )
local farm = require( 'farm' )
local keys = require( 'keys' )
local ru = require( 'redis-util' )
local rtask = require( 'remote-task' )

local logger = require( 'moon.logger' )
local set = require( 'moon.set' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )

local argparse = require( 'argparse' )
local signal = require( 'posix.signal' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local check_log_level = assert( farm.check_log_level )
local is_fast_node = assert( farm.is_fast_node )
local distributor_info = assert( cluster.distributor_info )

local debug = assert( logger.debug )
local info = assert( logger.info )
local sleep = assert( time.sleep )
local timeit_micros = assert( time.timeit_micros )

local format = assert( string.format )
local ceil = assert( math.ceil )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local SIGINT = assert( signal.SIGINT )
local SIGTERM = assert( signal.SIGTERM )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
-- Parsed CLI args will be put here.
local args

str.enable_string_injections()

local STOP = false

-----------------------------------------------------------------
-- Signals.
-----------------------------------------------------------------
local function handle_stop_signal( sig )
  assert( sig )
  signal.signal( sig, function()
    STOP = true
    info(
        'stop signal %d received: node manager waiting to exit...',
        sig )
  end )
end

handle_stop_signal( SIGINT )
handle_stop_signal( SIGTERM )

-----------------------------------------------------------------
-- Strategies
-----------------------------------------------------------------
local function push_queue( cxn, q, hash )
  assert( cxn )
  assert( hash )
  assert( type( hash ) == 'string' )
  assert( #hash > 0 )
  if not cxn:rpush( q, hash ) then
    error(
        format( 'failed to push hash %s onto queue %s', hash, q ) )
  end
end

local Stgy = {}

function Stgy.global( cxn, task_info )
  local hash = assert( task_info.hash )
  push_queue( cxn, keys.remote_global_queue(), hash )
  debug( 'distributed task %s to GLOBAL', hash )
  return true
end

-- The idea here is that we want the allowance to be large enough
-- such that if we have all of the large compile-time TUs active
-- at once then they can all get distributed to the fast nodes.
local function heavy_overschedule_allowance()
  local fast_nodes = config.nodes.FAST_NODES
  if fast_nodes == 0 then return 0 end
  local heavy_per_fast_node = config.distributor
                                  .TOP_COMPILE_TIME_COUNT /
                                  fast_nodes
  return ceil( heavy_per_fast_node )
end

function Stgy.smart( cxn, task_info )
  local hash = assert( task_info.hash )
  local query_time, state =
      timeit_micros( distributor_info, cxn )
  debug( 'queried cluster state: %.1f ms', query_time / 1000 )
  assert( state )
  local large_compile_times = set( assert(
                                       state.large_compile_times ) )
  local input_file_path = assert( task_info.input_file_path )
  local is_heavy =
      large_compile_times:contains( input_file_path )
  if is_heavy then
    debug( 'distributing heavy compile task for %s',
           input_file_path )
  end
  for _, node_label in ipairs( config.nodes.node_rank ) do
    -- This can happen if there are nodes in the ranking but
    -- which are not online now.
    if not state.nodes[node_label] then goto continue end
    local node = assert( state.nodes[node_label] )
    local active_workers = assert( node.active_worker_count )
    local total_workers = assert( node.worker_count )
    local local_workers = assert( node.local_worker_count )
    local local_active_workers = assert(
                                     node.local_active_worker_count )
    local remote_workers = total_workers - local_workers
    if remote_workers == 0 then goto continue end
    local remote_active_workers =
        active_workers - local_active_workers
    local remote_queue_size = assert( node.remote_queue_size )
    local have = remote_active_workers + remote_queue_size
    local want = remote_workers
    if is_heavy and is_fast_node( node_label ) then
      -- Allow some overscheduling on this node since this is a
      -- heavy compilation and this is a fast node.
      want = want + heavy_overschedule_allowance()
    end
    if have < want then
      assert( remote_workers > 0 )
      -- NOTE: no expiry here to avoid another hit to the redis
      -- server. Ideally it'd be config.expire.TASKS.
      push_queue( cxn, keys.remote_host_queue( node_label ), hash )
      debug( 'distributed task %s to %s: %s<%s', hash,
             node_label:split( '-' )[1], have, want )
      return true
    end
    ::continue::
  end
  return false
end

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function distribute( cxn, task_info )
  local hash = assert( task_info.hash )
  debug( 'distributing task %s', hash )
  local stgy_key = keys.distributor_stgy()
  local stgy = cxn:get( stgy_key ) or
                   config.distributor.DEFAULT_STGY
  assert( Stgy[stgy],
          format( 'unrecognized distribution strategy: %s',
                  tostring( stgy ) ) )
  local function fallback()
    warn( 'falling back to global strategy for task %s', hash )
    if stgy == 'global' then
      error( 'global strategy failed first attempt for hash %s',
             hash )
    end
    return Stgy.global( cxn, task_info )
  end
  return Stgy[stgy]( cxn, task_info ) or fallback()
end

local function run( cxn )
  assert( cxn )
  info( 'heavy_overschedule_allowance: %s',
        heavy_overschedule_allowance() )

  while not STOP do
    check_log_level( cxn ) -- self-throttling.
    local hash = cxn:blpop( keys.remote_distributor_queue(),
                            config.distributor
                                .QUEUE_POLL_TIMEOUT_SECS )
    hash = hash and hash[2]
    if not hash then goto continue end
    local task_info = assert( rtask.find( cxn, hash ) )
    if not distribute( cxn, task_info ) then
      warn( 'could not distribute task %s, will retry...' )
      cxn:lpush( keys.remote_distributor_queue(), hash )
      sleep( 1 )
    end
    ::continue::
  end
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local parser = argparse( arg[0], 'ReDist Task Distributor' )

  -- LuaFormatter off
  parser:option( '--verbosity' )
        :choices{ 'error', 'warning', 'info', 'debug', 'trace' }
        :default( 'info' )
        :description( 'log level' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  local cxn<close> = assert( ru.connect() )
  check_log_level( cxn )

  info( 'starting distributor' )

  run( cxn )

  info( 'leaving distributor' )
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
-- NOTE: we don't catch control-c here because that is suppose to
-- be done by the signal handlers above.
os.exit( main() )