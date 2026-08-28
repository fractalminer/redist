-----------------------------------------------------------------
-- Manages a pool of process replicas.
-----------------------------------------------------------------
local logger = require( 'moon.logger' )
local set = require( 'moon.set' )
local time = require( 'moon.time' )

local posix = require( 'posix' )
local signal = require( 'posix.signal' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )
local err = assert( logger.err )
local info = assert( logger.info )
local sleep = assert( time.sleep )
local warn = assert( logger.warn )

local execp = assert( posix.execp )
local fork = assert( posix.fork )
local killpg = assert( posix.killpg )
local wait = assert( posix.wait )

local format = assert( string.format )
local insert = assert( table.insert )
local max = assert( math.max )

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

function ProcessPool:log_pids()
  debug( 'running=%s, terminating=%s', self._running_pids,
         self._pending_term_pids )
end

function ProcessPool:running_count()
  return self._running_pids:size()
end

function ProcessPool:terminating_count()
  return self._pending_term_pids:size()
end

function ProcessPool:live_count()
  return self._running_pids:size() +
             self._pending_term_pids:size()
end

function ProcessPool:target_count()
  return assert( self._target_count ) --
end

function ProcessPool:command() return self._cmd end

function ProcessPool:inc( n )
  n = n or 1
  self._target_count = self._target_count + n
end

function ProcessPool:dec( n )
  n = n or 1
  self._target_count = max( self._target_count - n, 0 )
end

function ProcessPool:_check_running()
  local reaped_pids = set()
  for pid in self._running_pids do
    local updated_pid = wait( pid, WNOHANG )
    if updated_pid and updated_pid > 0 then
      assert( updated_pid == pid,
              format( '%s != %s', updated_pid, pid ) )
      -- This child died unexpectedly, so kill its process group
      -- just to make sure that it doesn't leave any orphans. We
      -- can do this because the process group still exists if
      -- there are children even after we've reaped the parent
      -- pid. Technically if there are no children then this
      -- process group could be reused and so there is actually a
      -- race in what we are about to do, but because we are
      -- doing it immediately after reaping, it should be fine.
      -- It prevents orphan processes from continuing to run
      -- which would then be out of our view.
      killpg( pid, signal.SIGTERM )
      err( 'child exited unexpectedly: pid=%d', pid )
      reaped_pids:add( pid )
    end
  end
  self._running_pids:subtract( reaped_pids )
end

function ProcessPool:_reap()
  local reaped_pids = set()
  for pid in self._pending_term_pids do
    local updated_pid = wait( pid, WNOHANG )
    if updated_pid and updated_pid > 0 then
      assert( updated_pid == pid,
              format( '%s != %s', updated_pid, pid ) )
      info( 'reaped pid %d', pid )
      reaped_pids:add( pid )
    end
  end
  self._pending_term_pids:subtract( reaped_pids )
end

function ProcessPool:stop( sig )
  sig = sig or signal.SIGTERM
  for pid in self._running_pids do
    warn( 'stopping child pid %d', pid )
    killpg( pid, signal.SIGTERM )
    self._pending_term_pids:add( pid )
  end
  self._running_pids:clear()
  while self._pending_term_pids:size() > 0 do
    info( 'waiting for children to stop...' )
    self:_reap()
    sleep( .1 )
  end
  self._target_count = 0
  info( 'process pool stopped.' )
end

-- "Stopped" means that there are no child process and we don't
-- want to create any.
function ProcessPool:stopped()
  return self:live_count() == 0 and self._target_count == 0
end

function ProcessPool:advance()
  self:_check_running()
  self:_reap()

  local need_change = self:target_count() - self:running_count()
  if need_change > 0 then
    for _ = 1, need_change do
      info( 'spawning new child' )
      self._running_pids:add( spawn( self:command() ) )
    end
  elseif need_change < 0 then
    for pid in self._running_pids do
      info( 'terminating process group %d', pid )
      killpg( pid, signal.SIGTERM )
      self._pending_term_pids:add( pid )
      need_change = need_change + 1
      if need_change == 0 then break end
    end
    self._running_pids:subtract( self._pending_term_pids )
    assert( need_change == 0,
            format( 'need_change == %d', need_change ) )
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

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return ProcessPool.new