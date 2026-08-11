-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local posix = require( 'posix' )
local printer = require( 'moon.printer' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local pipe = assert( posix.unistd.pipe )
local fork = assert( posix.unistd.fork )
local close = assert( posix.unistd.close )
local dup2 = assert( posix.unistd.dup2 )
local exec = assert( posix.unistd.exec )
local read = assert( posix.unistd.read )
local write = assert( posix.unistd.write )
local wait = assert( posix.sys.wait.wait )
local poll = assert( posix.poll.poll )

local posix_exit = assert( posix.unistd._exit )

local bar = assert( printer.bar )

local concat = assert( table.concat )
local insert = assert( table.insert )
local format = assert( string.format )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local STDOUT_FILENO = assert( posix.unistd.STDOUT_FILENO )
local STDERR_FILENO = assert( posix.unistd.STDERR_FILENO )

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function create_pipe()
  local r, w = pipe()
  assert( r, 'failed to create pipe' )
  assert( w, 'failed to create pipe' )
  return r, w
end

-- Run a file that is exactly at path `path` with the given
-- args and capture both stdout and stderr.
--
-- Args:
--   * path: exact path of executable.
--   * args: optional list of args.
--
-- Returns:
--   * status code
--   * stdout
--   * stderr
--
local function popen( path, args )
  args = args or {}

  local stdout_r, stdout_w = create_pipe()
  local stderr_r, stderr_w = create_pipe()

  local pid, fork_err = fork()
  assert( pid, format( 'failed to fork process: %s', fork_err ) )

  if pid == 0 then
    -- Child process.
    close( stdout_r )
    close( stderr_r )

    local function fail( reason )
      -- Since we are in the child process here we do error han-
      -- dling a bit different. We want to use posix write in-
      -- stead of lua's write to avoid the buffering that might
      -- happen as a result of the C file mechanism (used by Lua)
      -- that is layered on top of the posix one.
      write( STDERR_FILENO, reason )
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

    local _, exec_err = exec( path, args )
    fail( format( 'failed to execute command %s: %s', path,
                  exec_err ) )
  else
    close( stdout_w )
    close( stderr_w )

    local fds_remaining = {
      -- This is the input format required by the lua posix li-
      -- brary. The linux poll method will look at `events` to
      -- see which events we are interested in, then will return
      -- events by injecting an `revents` table after each poll
      -- containing the events we requested plus possibly some
      -- additional general ones (ERR, NVAL, HUP).
      [stdout_r]={ events={ IN=true } },
      [stderr_r]={ events={ IN=true } },
    }

    local function remove_fd( fd )
      assert( fds_remaining[fd] )
      close( fd )
      fds_remaining[fd] = nil
    end

    local chunks = { [stdout_r]={}, [stderr_r]={} }

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
    while next( fds_remaining ) do
      local n, poll_err = poll( fds_remaining, -1 )
      assert( n ~= nil, format( 'failed to poll: %s', poll_err ) )
      for fd in pairs( fds_remaining ) do
        local revents = fds_remaining[fd].revents or {}
        if revents.HUP then
          -- Child is done, so it is safe to drain until EOF
          -- without risking blocking indefinitely.
          repeat until not read_chunk_or_close( fd )
        elseif revents.IN then
          read_chunk_or_close( fd )
        elseif revents.ERR or revents.NVAL then
          remove_fd( fd )
        end
      end
    end

    local pid_ended, reason, status = wait( pid )
    assert( pid_ended ~= nil, format(
                'failed to wait for child process: status=%s, reason: %s',
                tostring( status ), reason ) )
    assert( pid_ended == pid,
            'unexpected pid returned after waiting for child process' )
    -- reason = 'exited', 'killed', or 'stopped'
    local stdout = concat( chunks[stdout_r] )
    local stderr = concat( chunks[stderr_r] )
    return status, stdout, stderr
  end
end

-----------------------------------------------------------------
-- Test
-----------------------------------------------------------------
local function title( name )
  bar()
  print( name )
  bar()
end

local function test( prog, ... )
  local status, stdout, stderr = popen( prog, { ... } )
  title( 'STDOUT' )
  io.write( stdout )
  title( 'STDERR' )
  io.write( stderr )
  title( format( 'STATUS: %d', status ) )
  return status
end

-----------------------------------------------------------------
-- Package.
-----------------------------------------------------------------
-- return { popen=popen }
os.exit( test( ... ) )