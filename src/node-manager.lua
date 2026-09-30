-----------------------------------------------------------------
-- Supervisor that runs a worker node.
-----------------------------------------------------------------
local config = require( 'config' )
local farm = require( 'farm' )
local keys = require( 'keys' )
local lcache = require( 'lcache' )
local network = require( 'network' )
local process_pool = require( 'process-pool' )
local ru = require( 'redis-util' )
local subprocess = require( 'subprocess' )

local logger = require( 'moon.logger' )
local mcleanup = require( 'moon.cleanup' )
local mmath = require( 'moon.math' )
local printer = require( 'moon.printer' )
local str = require( 'moon.str' )
local tbl = require( 'moon.tbl' )
local time = require( 'moon.time' )

local argparse = require( 'argparse' )
local signal = require( 'posix.signal' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local check_log_level = assert( farm.check_log_level )
local LocalCache = assert( lcache.LocalCache )
local ProcessPool = assert( process_pool.ProcessPool )
local set_hash = assert( ru.set_hash )
local wait_redis_available = assert( ru.wait_redis_available )
local WorkerCount = assert( farm.WorkerCount )

local chain = assert( mcleanup.chain )
local clamp = assert( mmath.clamp )
local cleanup = assert( mcleanup.cleanup )
local execute = assert( subprocess.execute )
local info = assert( logger.info )
local machine_label = assert( network.machine_label )
local now_seconds = assert( time.now_seconds )
local on_ordered_kv = assert( tbl.on_ordered_kv )
local sleep = assert( time.sleep )
local tcall = assert( time.tcall )
local section = assert( printer.section )

local concat = assert( table.concat )
local format = assert( string.format )
local insert = assert( table.insert )
local rep = assert( string.rep )

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

local LAST_EVICT = 0

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
    enabled=true,
    target=0,
    worker_type='both',
    cmd={ 'bash', 'run-worker.sh' },
    pool=nil,
    last_logged_count=0,
  },
  workers_remote={
    enabled=true,
    target=0,
    worker_type='remote',
    cmd={ 'bash', 'run-remote-worker.sh' },
    pool=nil,
    last_logged_count=0,
  },
  workers_local={
    enabled=true,
    target=0,
    worker_type='local',
    cmd={ 'bash', 'run-local-worker.sh' },
    pool=nil,
    last_logged_count=0,
  },
  node_stats_finder={
    enabled=true,
    target=1,
    worker_type=nil,
    cmd={ 'bash', 'run-node-stats-finder.sh' },
    pool=nil,
    last_logged_count=0,
  },
  distributor={
    -- This one will be enabled only when we are running this
    -- node maager on the same host as the redis server.
    enabled=false,
    target=1,
    worker_type=nil,
    cmd={ 'bash', 'run-distributor.sh' },
    pool=nil,
    last_logged_count=0,
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
  local _, running_on_redis_host = ru.resolve_host()
  if running_on_redis_host then
    info( 'enabling distributor' )
    assert( POOLS.distributor ).enabled = true
  end
  for name, conf in pairs( POOLS ) do
    if conf.enabled then insert( res, add_pool( name, conf ) ) end
  end
  return chain( res )
end

local function update_pool_count( conf )
  local pool = assert( conf.pool )
  local count = assert( pool:running_count() )
  if count == assert( conf.last_logged_count ) then return false end
  conf.last_logged_count = count
  return true
end

local function update_pool_counts()
  local need_log_counts = false
  for _, conf in pairs( POOLS ) do
    if conf.enabled then
      need_log_counts = update_pool_count( conf ) or
                            need_log_counts
    end
  end
  if not need_log_counts then return end
  local counts = {}
  on_ordered_kv( POOLS, function( _, conf )
    if not conf.enabled then return end
    local pool = assert( conf.pool )
    insert( counts,
            format( '[%-17s] %2d jobs running', pool:name(),
                    conf.last_logged_count ) )
  end )
  local bar = rep( '-', 65 )
  info( 'pools:\n%s\n%s\n%s', bar, concat( counts, '\n' ), bar )
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
  local key, ex = keys.node_manager_advertisement(
                      machine_label() )
  local sock = assert( cxn.network.socket )
  local ip, port, _ = sock:getsockname()
  local o = { ip=ip, port=port }
  set_hash( cxn, key, o, ex )
end

local function unadvertise_node( cxn )
  info( 'unadvertising node' )
  local key = keys.node_manager_advertisement( machine_label() )
  cxn:del( key )
end

local function evict_cache_throttled( lc )
  local now = now_seconds()
  if now < LAST_EVICT +
      config.node_manager.EVICT_CACHE_INTERVAL_SECS then return end
  LAST_EVICT = now
  tcall( info, 'sqlite evict', function() lc:evict() end )
end

local function should_stop() return STOP == true end

local function check_update( cxn )
  if STOP then return end
  local key = keys.update_node( machine_label() )
  if tonumber( cxn:get( key ) ) == 1 then
    cxn:del( key )
    info( 'UPDATING' )
    STOP = true
    execute( 'git', { 'pull' } )
  end
end

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function run()
  -- This is so that if the redis DB happens to be down then we
  -- will just wait for it here so that we don't keep crash
  -- looping (in which case systemd will stop starting us).
  wait_redis_available( should_stop )

  local cxn<close> = assert( ru.connect() )
  check_log_level( cxn )

  local _<close> = cleanup(
                       function() unadvertise_node( cxn ) end )

  local pools<close> = add_pools()

  local lc<close> = LocalCache()

  while not should_stop() do
    check_log_level( cxn ) -- self-throttling.
    advertise_node( cxn )
    evict_cache_throttled( lc )
    check_update( cxn )
    update_pool_counts()
    on_ordered_kv( POOLS, function( _, conf )
      if not conf.enabled then return end
      local pool = assert( conf.pool )
      pool:log_pids()
      adjust_pool_count( cxn, pool, conf )
      pool:advance()
    end )
    sleep( config.node_manager.ADVERTISE_INTERVAL_SECS )
  end
  return 0
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local parser = argparse( arg[0], 'ReDist Node Manager' )

  -- LuaFormatter off
  parser:option( '--verbosity' )
        :choices{ 'error', 'warning', 'info', 'debug', 'trace' }
        :default( 'info' )
        :description( 'log level' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  section( ' Redist Node Manager' )
  info( 'starting node manager: %s', machine_label() )

  return assert( tonumber( run() ) )
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
-- NOTE: we don't catch control-c here because that is suppose to
-- be done by the signal handlers above.
os.exit( main() )
