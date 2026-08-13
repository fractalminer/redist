local subprocess = require( 'subprocess' )
local printer = require( 'moon.printer' )

local popen = assert( subprocess.popen )
local CANCEL_PROCESS = assert( subprocess.CANCEL_PROCESS )

local title = assert( printer.title )
local printfln = assert( printer.printfln )

local function main( prog, ... )
  assert( prog )
  local args = { ... }
  local polls = 0
  local function on_poll()
    -- printfln( 'on_poll: %d', polls )
    polls = polls + 1
    if polls > 10000 then return CANCEL_PROCESS end
    -- if polls > 10 then return error( 'fail' ) end
  end
  local opts = {
    use_path_env=true,
    poll_timeout_millis=200,
    on_poll=on_poll,
  }
  local status, stdout, stderr, reason =
      popen( prog, args, opts )
  title( 'STDOUT' )
  io.write( stdout )
  title( 'STDERR' )
  io.write( stderr )
  title( 'STATS' )
  printfln( 'STATUS: %d', status )
  printfln( 'REASON: %s', reason )
  printfln( 'POLLS:  %d', polls )
  return status
end

os.exit( main( ... ) )
