-----------------------------------------------------------------
-- Supervisor that runs a worker node.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local network = require( 'network' )
local process_pool = require( 'process-pool' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local mcleanup = require( 'moon.cleanup' )
local mmath = require( 'moon.math' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )

local argparse = require( 'argparse' )
local signal = require( 'posix.signal' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local ProcessPool = assert( process_pool.ProcessPool )
local WorkerCount = assert( farm.WorkerCount )

local chain = assert( mcleanup.chain )
local clamp = assert( mmath.clamp )
local cleanup = assert( mcleanup.cleanup )
local debug = assert( logger.debug )
local info = assert( logger.info )
local machine_label = assert( network.machine_label )
local sleep = assert( time.sleep )

local format = assert( string.format )
local insert = assert( table.insert )

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
-- Process Pools.
-----------------------------------------------------------------
local POOLS = {
  workers_both={
    target=0,
    worker_type='both',
    cmd={ 'bash', 'run-worker.sh' },
    pool=nil,
  },
  workers_remote={
    target=0,
    worker_type='remote',
    cmd={ 'bash', 'run-remote-worker.sh' },
    pool=nil,
  },
  workers_local={
    target=0,
    worker_type='local',
    cmd={ 'bash', 'run-local-worker.sh' },
    pool=nil,
  },
  node_stats_finder={
    target=0,
    worker_type=nil,
    cmd={ 'bash', 'run-node-stats-finder.sh' },
    pool=nil,
  },
}

local function add_pool( name, conf )
  assert( name )
  local cmd = assert( conf.cmd )
  local target = assert( conf.target )
  conf.pool = ProcessPool{ cmd=cmd, target=target, name=name }
  return cleanup( function() conf.pool:stop() end )
end

local function add_pools()
  local res = {}
  for name, conf in pairs( POOLS ) do
    insert( res, add_pool( name, conf ) )
  end
  return chain( res )
end

local function adjust_pool_count( cxn, pool, conf )
  if not conf.worker_type then return end
  local worker_count = WorkerCount( cxn, machine_label(),
                                    conf.worker_type )
  local count = worker_count:get()
  count = clamp( count, 0,
                 config.node_manager.MAX_WORKERS_PER_TYPE )
  pool:set( count )
end

local function advertise_node( cxn )
  local key = format( 'farm:node:%s:presence:manager',
                      machine_label() )
  cxn:set( key, 1 )
  cxn:expire( key, config.node_manager.EXPIRE_ADVERTISE_SECS )
end

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function run( cxn )
  assert( cxn )

  local pools<close> = add_pools()

  while not STOP do
    advertise_node( cxn )
    for _, conf in pairs( POOLS ) do
      local pool = assert( conf.pool )
      debug( '[%s] [%d] running', pool:name(),
             pool:running_count() )
      pool:log_pids()
      adjust_pool_count( cxn, pool, conf )
      pool:advance()
    end
    sleep( 1.0 )
  end
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
        :default( 'debug' )
        :description( 'log level' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  local cxn<close> = assert( ru.connect() )

  info( 'starting node manager: %s', machine_label() )

  run( cxn )
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
-- NOTE: we don't catch control-c here because that is suppose to
-- be done by the signal handlers above.
os.exit( main() )
