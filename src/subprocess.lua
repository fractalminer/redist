-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local pipe = assert( posix.unistd.pipe )
local fork = assert( posix.unistd.fork )
local close = assert( posix.unistd.close )
local dup2 = assert( posix.unistd.dup2 )
local exec = assert( posix.unistd.exec )
local execp = assert( posix.unistd.execp )
local read = assert( posix.unistd.read )
local write = assert( posix.unistd.write )
local kill = assert( posix.signal.kill )
local wait = assert( posix.sys.wait.wait )
local poll = assert( posix.poll.poll )

local posix_exit = assert( posix.unistd._exit )
local chdir = assert( posix.unistd.chdir )

-- local format_table = assert( printer.format_kv_table )

local concat = assert( table.concat )
local insert = assert( table.insert )
local format = assert( string.format )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local STDOUT_FILENO = assert( posix.unistd.STDOUT_FILENO )
local STDERR_FILENO = assert( posix.unistd.STDERR_FILENO )
local SIGTERM = assert( posix.signal.SIGTERM )

local CANCEL_PROCESS = {}

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function create_pipe()
  local r, w = pipe()
  assert( r, 'failed to create pipe' )
  assert( w, 'failed to create pipe' )
  return r, w
end

local function cleanup( fn )
  return setmetatable( {}, {
    __close=function( self ) fn( self ) end,
  } )
end

-- Run a file that is exactly at path `path` with the given
-- args and capture both stdout and stderr.
--
-- Args:
--   * path: exact path of executable.
--   * args: optional list of program args.
--   * opts:
--       - poll_timeout_millis: while polling for output to the
--         streams we will break after (at most) this much time
--         to allow the callback to be called.
--       - on_poll: called just before calling poll. As such, it
--         will be called at most every poll_timeout_millis or on
--         each input event, whichever comes first. If no poll
--         timeout is specified then this method may only be
--         called once (before the first poll).
--
-- Returns:
--   * status code
--   * stdout
--   * stderr
--
local function popen( path, args, opts )
  assert( path, 'invalid path' )
  args = args or {}
  opts = opts or {}

  opts.use_path_env = opts.use_path_env or false
  opts.poll_timeout_millis = opts.poll_timeout_millis or -1
  opts.on_poll = opts.on_poll or nil
  opts.cwd = opts.cwd or nil

  local stdout_r, stdout_w = create_pipe()
  local stderr_r, stderr_w = create_pipe()

  local pid, fork_err = fork()
  assert( pid, format( 'failed to fork process: %s', fork_err ) )

  if pid == 0 then
    if opts.cwd then assert( chdir( opts.cwd ) ) end

    -- Child process.
    close( stdout_r )
    close( stderr_r )

    local function fail( reason )
      -- Since we are in the child process here we do error han-
      -- dling a bit different. We want to use posix write in-
      -- stead of lua's write to avoid the buffering that might
      -- happen as a result of the C file mechanism (used by Lua)
      -- that is layered on top of the posix one.
      write( STDERR_FILENO, reason .. '\n' )
      posix_exit( 1 )
    end

    local function make_dupe( fd, new_fd )
      local ok, err = dup2( fd, new_fd )
      if ok then return end
      fail( format( 'failed to dup2 file descriptor: %s', err ) )
    end

    make_dupe( stdout_w, STDOUT_FILENO )
    make_dupe( stderr_w, STDERR_FILENO )
    close( stdout_w )
    close( stderr_w )

    local runner = opts.use_path_env and execp or exec
    local _, exec_err = runner( path, args )
    fail( format( 'failed to execute command %s: %s', path,
                  exec_err ) )
  else
    close( stdout_w )
    close( stderr_w )

    local fds = {
      -- This is the input format required by the lua posix li-
      -- brary. The linux poll method will look at `events` to
      -- see which events we are interested in, then will return
      -- events by injecting an `revents` table after each poll
      -- containing the events we requested plus possibly some
      -- additional general ones (ERR, NVAL, HUP).
      [stdout_r]={ events={ IN=true } },
      [stderr_r]={ events={ IN=true } },
    }

    -- We need cleanup on either an error or an early return, but
    -- not after natural termination.
    local closer<close> = cleanup( function( o )
      -- Since we're in a __close method, try to prevent any fur-
      -- ther errors from being thrown by using pcall.
      for fd in pairs( fds ) do pcall( close, fd ) end
      if o.child_is_owned then
        pcall( kill, pid, SIGTERM ) -- terminate child.
        pcall( wait, pid ) -- reap child.
      end
    end )
    closer.child_is_owned = true

    local function remove_fd( fd )
      assert( fds[fd] )
      close( fd )
      fds[fd] = nil
    end

    local chunks = { [stdout_r]={}, [stderr_r]={} }

    local function done_with_status( status, reason )
      local stdout = concat( chunks[stdout_r] )
      local stderr = concat( chunks[stderr_r] )
      return status, stdout, stderr, reason
    end

    local function save( fd, buf ) insert( chunks[fd], buf ) end

    local function read_chunk_or_close( fd )
      local buf, read_err = read( fd, 4096 )
      assert( buf ~= nil, format(
                  'failed to read from file descriptor: %s',
                  read_err ) )
      if #buf == 0 then
        remove_fd( fd )
        return nil
      end
      save( fd, buf )
      return #buf
    end

    -- The idea here is that we want to read all the bytes from
    -- both stdout_r and stderr_r, but we can't do one and then
    -- the other, since due to buffering it is possible that we
    -- could get into a deadlock (e.g. child is blocked trying to
    -- write to stderr which is not being drained because we are
    -- still reading stdout). So the solution to that is that we
    -- need to read both together. To do that we use the posix
    -- poll method where we can give it a list of file descrip-
    -- tors and it will return when there is an event, and it
    -- will tell us which file descriptor had the event and which
    -- event.
    while next( fds ) do
      -- If the callback requests cancellation, returning here is
      -- safe: the scope guard will close the pipes, terminate
      -- the direct child, and reap it.
      if opts.on_poll and opts.on_poll() == CANCEL_PROCESS then
        return done_with_status( 1, 'cancelled' )
      end
      local n, poll_err = poll( fds, opts.poll_timeout_millis )
      assert( n ~= nil, format( 'failed to poll: %s', poll_err ) )
      -- If poll returned due to timeout then do not try to read
      -- anything as revents won't have been updated by luaposix
      -- and thus may hold stale values that could cause us to
      -- block trying to read data that isn't there.
      if n == 0 then goto continue end
      for fd in pairs( fds ) do
        local revents = fds[fd].revents or {}
        if revents.HUP then
          -- There are no remaining writers for this pipe, so it
          -- is safe to drain until EOF without blocking indefi-
          -- nitely, though the child may still be running.
          repeat until not read_chunk_or_close( fd )
        elseif revents.IN then
          read_chunk_or_close( fd )
        elseif revents.ERR or revents.NVAL then
          remove_fd( fd )
        end
      end
      ::continue::
    end

    local pid_ended, reason, status = wait( pid )
    assert( pid_ended ~= nil, format(
                'failed to wait for child process: status=%s, reason: %s',
                tostring( status ), reason ) )
    assert( pid_ended == pid,
            'unexpected pid returned after waiting for child process' )
    closer.child_is_owned = false -- cleanup no longer needed.
    -- reason here could be: exited / killed / stopped
    return done_with_status( status, reason )
  end
end

-----------------------------------------------------------------
-- Package.
-----------------------------------------------------------------
return { popen=popen, CANCEL_PROCESS=CANCEL_PROCESS }