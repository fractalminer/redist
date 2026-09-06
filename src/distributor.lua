-----------------------------------------------------------------
-- Distributes tasks.
-----------------------------------------------------------------
local cluster = require( 'cluster' )
local config = require( 'config' )
local keys = require( 'keys' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )

local argparse = require( 'argparse' )
local signal = require( 'posix.signal' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local query_cluster_state = assert( cluster.query_cluster_state )

local debug = assert( logger.debug )
local info = assert( logger.info )
local sleep = assert( time.sleep )
local timeit_micros = assert( time.timeit_micros )

local format = assert( string.format )

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
-- Caches.
-----------------------------------------------------------------

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

function Stgy.global( cxn, hash )
  push_queue( cxn, keys.remote_global_queue(), hash )
  debug( 'distributed task %s to GLOBAL', hash )
  return true
end

function Stgy.smart( cxn, hash )
  -- TODO: this is probably too slow.
  local query_time, state = timeit_micros( function()
    return query_cluster_state( cxn, {
      exclude_workers=true, --
    } )
  end )
  debug( 'queried cluster state: %s us', query_time )
  assert( state )
  for _, node_label in ipairs( state.node_rank ) do
    -- This can happen if there are nodes in the ranking in redis
    -- but which are not online now.
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
    local want = math.floor( remote_workers + 2 )
    if have < want then
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
local function distribute( cxn, hash )
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
    return Stgy.global( cxn, hash )
  end
  return Stgy[stgy]( cxn, hash ) or fallback()
end

local function run( cxn )
  assert( cxn )

  while not STOP do
    local hash = cxn:blpop( keys.remote_distributor_queue(),
                            config.distributor
                                .QUEUE_POLL_TIMEOUT_SECS )
    hash = hash and hash[2]
    if not hash then goto continue end
    if not distribute( cxn, hash ) then
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
        :default( 'debug' )
        :description( 'log level' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  local cxn<close> = assert( ru.connect() )

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