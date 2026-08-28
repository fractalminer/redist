local process_pool = require( 'process-pool' )
local logger = require( 'moon.logger' )
local time = require( 'moon.time' )

local signal = require( 'posix.signal' )

local debug = assert( logger.debug )
local err = assert( logger.err )

local ProcessPool = assert( process_pool.ProcessPool )

local cmd = { 'bash', 'test.sh', 'hello' }

local stop = false

logger.level = logger.levels.INFO

signal.signal( signal.SIGINT, function() stop = true end )
signal.signal( signal.SIGTERM, function() stop = true end )

local function hold( pool, n )
  pool:set( n )
  while not stop do
    debug( '[%d] running', pool:running_count() )
    pool:log_pids()
    pool:advance()
    time.sleep( 1 )
  end
end

local function ramp( pool )
  local peak = 10
  local increasing = true
  local update_iters = 10
  local iters = 0
  while not stop do
    debug( '[%d] running', pool:running_count() )
    pool:log_pids()
    pool:advance()
    time.sleep( .3 )
    iters = iters + 1
    if iters >= update_iters then
      iters = 0
      if pool:running_count() > peak then increasing = false end
      if pool:running_count() == 0 then increasing = true end
      if increasing then
        debug( '[%d] adding a process...', pool:target() )
        pool:inc( 2 )
      else
        debug( '[%d] removing a process...', pool:target() )
        pool:dec( 2 )
      end
    end
  end
end

local function main()
  do
    local pool<close> = ProcessPool{ cmd=cmd }
    stop = false
    ramp( pool )
  end
  do
    local pool<close> = ProcessPool{ cmd=cmd }
    stop = false
    hold( pool, 1 )
  end
  do
    local pool<close> = ProcessPool{ cmd=cmd }
    stop = false
    hold( pool, 10 )
  end
end

local ok, msg = pcall( main )
if not ok then
  err( msg )
else
  print( 'finished.' )
end