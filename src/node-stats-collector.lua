-----------------------------------------------------------------
-- Stats collector that runs on a node and collects host stats.
-----------------------------------------------------------------
local config = require( 'config' )
local network = require( 'network' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local str = require( 'moon.str' )
local time = require( 'moon.time' )
local printer = require( 'moon.printer' )

local argparse = require( 'argparse' )
local signal = require( 'posix.signal' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )
local format_table = assert( printer.format_table )
local info = assert( logger.info )
local machine_label = assert( network.machine_label )
local set_hash = assert( ru.set_hash )
local sleep = assert( time.sleep )

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
-- CPU/RAM Usage.
-----------------------------------------------------------------
local function read_cpu_info()
  local f<close> = assert( io.open( '/proc/stat', 'r' ) )

  local function next_line() return f:read( '*l' ) end
  local line = assert( next_line() )

  local values = {}
  for n in line:gmatch( '%d+' ) do
    values[#values + 1] = tonumber( n )
  end

  local user = values[1]
  local nice = values[2]
  local system = values[3]
  local idle = values[4]
  local iowait = values[5]
  local irq = values[6]
  local softirq = values[7]
  local steal = values[8]

  local total_ticks =
      user + nice + system + idle + iowait + irq + softirq +
          steal
  local idle_ticks = idle + iowait

  local cpu_used = total_ticks - idle_ticks

  local cpus = 0
  line = next_line()
  while line and line:match( '^cpu%d+ ' ) do
    cpus = cpus + 1
    line = next_line()
  end

  return {
    cpus=cpus,
    cpu_total_ticks=total_ticks,
    cpu_used_ticks=cpu_used,
  }
end

local function cpu_percent_used( s1, s2 )
  local delta_cpu_total_ticks = s2.cpu_total_ticks -
                                    s1.cpu_total_ticks
  local delta_cpu_used_ticks = s2.cpu_used_ticks -
                                   s1.cpu_used_ticks
  local percent_used = delta_cpu_used_ticks /
                           delta_cpu_total_ticks
  assert( s1.cpus == s2.cpus )
  local cores_used = s1.cpus * percent_used
  return { percent_used=percent_used, cores_used=cores_used }
end

local function read_mem_usage()
  local f<close> = assert( io.open( '/proc/meminfo', 'r' ) )

  local total_kb, available_kb

  for line in f:lines() do
    local key, value = line:match( '^(%w+):%s+(%d+)' )
    if key == 'MemTotal' then
      total_kb = tonumber( value )
    elseif key == 'MemAvailable' then
      available_kb = tonumber( value )
    end
  end

  assert( total_kb and available_kb )
  local used_kb = total_kb - available_kb
  local total_gb = total_kb / 1000000
  return { total_gb=total_gb, percent_used=used_kb / total_kb }
end

local function broadcast_stats(cxn, cores_total, cpu_usage,
                               mem_usage )
  local key = format( 'farm:node:%s:stats', machine_label() )
  local stats = {
    cores_total=assert( cores_total ),
    cores_percent_used=assert( cpu_usage.percent_used ),
    mem_total_gb=assert( mem_usage.total_gb ),
    mem_percent_used=assert( mem_usage.percent_used ),
  }
  info( 'broadcasting stats: %s', format_table( stats ) )
  set_hash( cxn, key, stats,
            config.stats_collector.EXPIRE_ADVERTISE_SECS )
end

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function run( cxn )
  assert( cxn )

  local last_sample = read_cpu_info()
  local cpu_usage
  while not STOP do
    local sample = read_cpu_info()
    debug( 'cpu sample: %s', format_table( sample ) )
    cpu_usage = cpu_percent_used( last_sample, sample )
    local mem_usage = read_mem_usage()
    broadcast_stats( cxn, sample.cpus, cpu_usage, mem_usage )
    last_sample = sample
    sleep( 1.0 )
  end
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local parser =
      argparse( arg[0], 'ReDist Node Stats Collector' )

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

  info( 'starting stats collector: %s', machine_label() )

  run( cxn )
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
-- NOTE: we don't catch control-c here because that is suppose to
-- be done by the signal handlers above.
os.exit( main() )
