local process_pool = require( 'process_pool' )
local posix = require( 'posix' )
local printer = require( 'moon.printer' )

local printfln = assert( printer.printfln )

local increasing = true
local peak = 5

local pool = process_pool{ cmd={ 'bash', 'test.sh', 'hello' } }

local update_iters = 5
local iters = 0

while increasing or pool:count_running() > 0 do
  printfln( '[%d] running', pool:count_running() )
  pool:advance()
  posix.sleep( 1 )
  iters = iters + 1
  if iters >= update_iters then
    iters = 0
    if pool:count_running() >= peak then increasing = false end
    if increasing then
      printfln( '[%d] adding a process...', pool:count_target() )
      pool:add()
    else
      printfln( '[%d] removing a process...', pool:count_target() )
      pool:remove()
    end
  end
end

print( 'finished.' )