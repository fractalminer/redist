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

local logger = require( 'moon.logger' )
local mcleanup = require( 'moon.cleanup' )
local mmath = require( 'moon.math' )
local printer = require( 'moon.printer' )
local str = require( 'moon.str' )
local subprocess = require( 'moon.subprocess' )
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
local remove_worker_presence = assert(
                                   farm.remove_worker_presence )
local set_hash = assert( ru.set_hash )
local wait_redis_available = assert( ru.wait_redis_available )
local wait_local_redis_available = assert(
                                       ru.wait_local_redis_available )
local WorkerCount = assert( farm.WorkerCount )

local chain = assert( mcleanup.chain )
local clamp = assert( mmath.clamp )
local cleanup = assert( mcleanup.cleanup )
local execute = assert( subprocess.execute )
local debug = assert( logger.debug )
local err = assert( logger.err )
local info = assert( logger.info )
local warning = assert( logger.warning )
local machine_label = assert( network.machine_label )
local now_seconds = assert( time.now_seconds )
local on_ordered_kv = assert( tbl.on_ordered_kv )
local sleep = assert( time.sleep )
local tcall = assert( time.tcall )
local section = assert( printer.section )

local concat = assert( table.concat )
local format = assert( string.format )
local insert = assert( table.insert )
local min = assert( math.min )
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
local LAST_AUTO_SCALE = 0
local LAST_AUTO_UNSCALE = now_seconds()

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

local function pid_exists( pid )
  local ok, _, _ = signal.kill( pid, 0 )
  return ok ~= nil
end

-----------------------------------------------------------------
-- Process Pools.
-----------------------------------------------------------------
local POOLS = {
  -- NOTE: local redis should go first because subsequent jobs
  -- (workers) will need to connect to it. If they can't then
  -- they will fail initially to come up; eventually they will be
  -- brought back up so there is not permanent damage, but it
  -- logs errors so we should avoid it. So we do two things: 1)
  -- put redis first, and 2) add a delay.
  redis_local={
    enabled=true,
    target=1,
    worker_type=nil,
    cmd={ 'redis-server', '../conf/redis-local.conf' },
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
  node_telemetry={
    enabled=true,
    target=1,
    worker_type=nil,
    cmd={ 'bash', 'run-node-telemetry.sh' },
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

local function auto_scale_local_workers( cxn, l_cxn )
  local q_local = keys.local_queue( machine_label() )
  local size = assert( tonumber( l_cxn:llen( q_local ) ) )
  assert( size >= 0 )
  if size == 0 then return end
  -- Need to scale up.
  local key = assert( keys.node_telemetry( machine_label() ) )
  local cores = tonumber( cxn:hget( key, 'cores_total' ) )
  if not cores then err( 'failed to get total cores for host' ) end
  local local_workers = cores + 2
  local_workers = min( local_workers,
                       config.node_manager.MAX_WORKERS_PER_TYPE )
  info( 'auto-scaling local worker count to %d', local_workers )
  local wc = WorkerCount( cxn, machine_label(), 'local' )
  if wc:get() > 0 then return end
  wc:set( local_workers )
end

local function auto_scale_local_workers_throttled( cxn, l_cxn )
  assert( cxn )
  assert( l_cxn )
  if not config.node_manager.ENABLE_LOCAL_AUTO_SCALE then return end
  local now = now_seconds()
  if now < LAST_AUTO_SCALE +
      config.node_manager.CHECK_LOCAL_AUTO_SCALE_INTERVAL_SECS then
    return
  end
  LAST_AUTO_SCALE = now
  auto_scale_local_workers( cxn, l_cxn )
end

local function auto_unscale_local_workers( cxn )
  debug( 'checking local worker activity...' )
  local workers_glob = keys.worker_advertisement(
                           machine_label(), '*' )
  local worker_keys = cxn:keys( workers_glob )
  assert( type( worker_keys ) == 'table' )
  if #worker_keys == 0 then return end
  local now = now_seconds()

  local timeout = config.node_manager
                      .LOCAL_WORKER_INACTIVITY_TIMEOUT_SECS
  for _, worker_key in ipairs( worker_keys ) do
    local advert = cxn:hgetall( worker_key )
    assert( type( advert ) == 'table' )
    if next( advert ) then
      if assert( advert.listen ) == 'local' then
        local last_active = assert(
                                tonumber( advert.last_active ) )
        if last_active + timeout > now then return end
      end
    end
  end
  -- All local workers have timed out, meaning that they've gone
  -- a period of time with no activity.
  info( 'stopping local workers due to inactivity.' )
  WorkerCount( cxn, machine_label(), 'local' ):set( 0 )
end

local function auto_unscale_local_workers_throttled( cxn )
  assert( cxn )
  if not config.node_manager.ENABLE_LOCAL_AUTO_SCALE then return end
  local now = now_seconds()
  if now < LAST_AUTO_UNSCALE +
      config.node_manager.CHECK_LOCAL_AUTO_UNSCALE_INTERVAL_SECS then
    return
  end
  LAST_AUTO_UNSCALE = now
  auto_unscale_local_workers( cxn )
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

local function remove_stale_worker_pids( cxn )
  local presence_sets = {
    'workers_active', --
    'workers_active_local', --
    'workers_count', --
    'workers_local', --
  }
  for _, ps in ipairs( presence_sets ) do
    local key = keys.worker_presence_set( machine_label(), ps )
    for _, pid in ipairs( cxn:smembers( key ) ) do
      if not pid_exists( tonumber( pid ) ) then
        warning( 'removing stale pid %s from %s presence set',
                 pid, ps )
        remove_worker_presence( cxn, ps, tonumber( pid ) )
      end
    end
  end
end

local function reset_node_worker_deaths( cxn )
  local key_count = keys.node_worker_deaths( machine_label() )
  cxn:del( key_count )
end

local function update_unexpected_deaths( cxn, pool )
  local died = assert( pool:pids_newly_died() )
  local died_count = assert( died:size() )
  if died_count == 0 then return end
  local key_count = keys.node_worker_deaths( machine_label() )
  for pid in died do
    err( 'unexpected worker death: parent_pid=%s', pid )
    -- This number will be shown on the dashboard.
    cxn:incr( key_count )
  end
  -- Just in case the worker died without unadvertising itself we
  -- need to remove them from the worker presence sets. Unfortu-
  -- nately we can't rely on expiries for that because individual
  -- set elements don't expire in redis.
  --
  -- NOTE: unfortunately, the PIDs in the `died` set are the pids
  -- of the wrapper shell scripts run-worker.sh and not the PIDs
  -- of the workers themselves, thus we can't remove them di-
  -- rectly from the worker presence sets in redis since they
  -- won't be in there. So instead we have to iterate over all
  -- the PIDs in those sets to check if they are still alive.
  remove_stale_worker_pids( cxn )
end

local function advance_pools( cxn )
  on_ordered_kv( POOLS, function( _, conf )
    if not conf.enabled then return end
    local pool = assert( conf.pool )
    pool:log_pids()
    adjust_pool_count( cxn, pool, conf )
    pool:advance()
    update_unexpected_deaths( cxn, pool )
  end )
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

  reset_node_worker_deaths( cxn )

  local _<close> = cleanup(
                       function() unadvertise_node( cxn ) end )

  local pools<close> = add_pools()
  -- Kick it once to start things up.
  advance_pools( cxn )

  -- We've just started up the local redis server, and it might
  -- take a few seconds before we can connect.
  wait_local_redis_available( should_stop )

  -- This should auto close before we clean up the pools, which
  -- matters because the local redis server is among the jobs in
  -- the pool.
  local l_cxn<close> = assert( ru.connect_local() )

  local lc<close> = LocalCache()

  while not should_stop() do
    check_log_level( cxn ) -- self-throttling.
    advertise_node( cxn )
    evict_cache_throttled( lc )
    check_update( cxn )
    update_pool_counts()
    auto_scale_local_workers_throttled( cxn, l_cxn )
    auto_unscale_local_workers_throttled( cxn )
    advance_pools( cxn )
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
