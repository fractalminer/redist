-----------------------------------------------------------------
-- Manages a pool of process replicas.
-----------------------------------------------------------------
local set = require( 'moon.set' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local fork = assert( posix.fork )
local execp = assert( posix.execp )
local wait = assert( posix.wait )

local max = assert( math.max )
local insert = assert( table.insert )

local WNOHANG = assert( posix.WNOHANG )

-----------------------------------------------------------------
-- Helpers.
-----------------------------------------------------------------
local function spawn( command )
  assert( command )
  assert( type( command ) == 'table' )
  assert( #command > 0 )
  assert( #command[1] > 0 )
  local program
  local args = {}
  for _, elem in ipairs( command ) do
    if not program then
      program = elem
    else
      insert( args, elem )
    end
  end
  assert( program )
  local pid = assert( fork() )
  if pid == 0 then
    -- Put this child process in its own process group. That way,
    -- it an any children that it spawns (which we don't have to
    -- know about here) can all be sent a signal together which
    -- is useful when the pool needs to terminate this child.
    posix.setpid( 'p', 0, 0 )
    -- We're in the child process.
    execp( program, args )
    os.exit( 127 ) -- fallback if execp fails.
  end
  -- We're in the parent process, pid=child.
  return pid
end

-----------------------------------------------------------------
-- Process Pool.
-----------------------------------------------------------------
local ProcessPool = {}

function ProcessPool:count_running()
  return self._running_pids:size()
end

function ProcessPool:count_terminating()
  return self._pending_term_pids:size()
end

function ProcessPool:count_live()
  return self._running_pids:size() +
             self._pending_term_pids:size()
end

function ProcessPool:count_target()
  return assert( self._target_count ) --
end

function ProcessPool:command() return self._cmd end

function ProcessPool:add( n )
  n = n or 1
  self._target_count = self._target_count + n
end

function ProcessPool:remove( n )
  n = n or 1
  self._target_count = max( self._target_count - n, 0 )
end

function ProcessPool:signal( what )
  -- TODO
end

function ProcessPool:advance()
  if self:count_running() > 0 then
    for pid in self._running_pids:iter() do
      local updated_pid = wait( pid, WNOHANG )
      if updated_pid == pid then
        error( 'not sure what to do here 2' )
      end
    end
  end
  local need_change = self:count_target() - self:count_running()
  if need_change > 0 then
    self._running_pids[spawn( self:command() )] = true
  elseif need_change < 0 then
    error( 'not sure what to do here 3' )
  end
end

function ProcessPool.new( opts )
  assert( opts, 'missing options argument' )
  assert( opts.cmd )
  local o = {
    _cmd=opts.cmd, --
    _target_count=0, --
    _running_pids=set(), --
    _pending_term_pids=set(), --
  }
  return setmetatable( o, {
    __newindex=function()
      error( 'cannot modify process pool.', 2 )
    end,
    __index=ProcessPool,
    __metatable=false,
  } )
end

setmetatable( ProcessPool, {
  __call=function( _, ... ) return ProcessPool.new( ... ) end,
} )

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return ProcessPool