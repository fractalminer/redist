local process_pool = require( 'process_pool' )
local logger = require( 'moon.logger' )
local time = require( 'moon.time' )

local signal = require( 'posix.signal' )

local debug = assert( logger.debug )

local increasing = true
local peak = 5

local pool = process_pool{ cmd={ 'bash', 'test.sh', 'hello' } }

local update_iters = 10
local iters = 0

local stop = false

logger.level = logger.levels.INFO

signal.signal( signal.SIGINT, function() stop = true end )
signal.signal( signal.SIGTERM, function() stop = true end )

local function ramp()
  while not stop do
    debug( '[%d] running', pool:running_count() )
    pool:log_pids()
    pool:advance()
    time.sleep( .3 )
    iters = iters + 1
    if iters >= update_iters then
      iters = 0
      if pool:running_count() >= peak then
        increasing = false
      end
      if pool:running_count() == 0 then increasing = true end
      if increasing then
        debug( '[%d] adding a process...', pool:target_count() )
        pool:inc( 2 )
      else
        debug( '[%d] removing a process...', pool:target_count() )
        pool:dec( 2 )
      end
    end
  end
end

pcall( ramp )
pool:stop()
print( 'finished.' )