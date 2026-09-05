-----------------------------------------------------------------
-- terminal.lua
--
-- Minimal TUI terminal support using:
--
--   * POSIX termios for keyboard setup.
--   * ANSI/VT escape sequences for output.
--   * Buffered, non-blocking keyboard decoding.
--   * Table-backed output buffers.
--
-- No curses.
-----------------------------------------------------------------
local M = {}

local termio = require( 'posix.termio' )
local unistd = require( 'posix.unistd' )
local time = require( 'posix.time' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local tcgetattr = assert( termio.tcgetattr )
local tcsetattr = assert( termio.tcsetattr )
local tcgetwinsize = assert( termio.tcgetwinsize )

local read = assert( unistd.read )
local write = assert( unistd.write )

local clock_gettime = assert( time.clock_gettime )

local STDIN = assert( unistd.STDIN_FILENO )
local STDOUT = assert( unistd.STDOUT_FILENO )

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local CSI = '\27['

-- How long an ESC byte is held while waiting to see if it begins
-- an escape sequence. 30 ms should be essentially unnoticeable
-- for a literal Escape key while being plenty of time for the
-- remainder of a terminal-generated key sequence to arrive.
local ESC_TIMEOUT = 0.030

-----------------------------------------------------------------
-- Helpers.
-----------------------------------------------------------------
local function deep_copy( x )
  if type( x ) ~= 'table' then return x end

  local res = {}
  for k, v in pairs( x ) do res[k] = deep_copy( v ) end
  return res
end

local function monotonic_seconds()
  local t = assert( clock_gettime( time.CLOCK_MONOTONIC ) )
  return t.tv_sec + t.tv_nsec / 1e9
end

local function write_all( fd, s )
  local offset = 0

  while offset < #s do
    local n, err = write( fd, s, #s - offset, offset )
    if not n then return nil, err end
    offset = offset + n
  end

  return true
end

-----------------------------------------------------------------
-- Terminal mode.
-----------------------------------------------------------------
local original_termios = nil
local initialized = false

function M.init()
  if initialized then return end

  original_termios = assert( tcgetattr( STDIN ) )

  local t = deep_copy( original_termios )

  -- Make characters available immediately and prevent the tty
  -- driver from echoing them to the screen.
  --
  -- Leave ISIG enabled. Thus Ctrl-C, Ctrl-Z, etc. retain their
  -- normal signal semantics.
  t.lflag = t.lflag & ~termio.ICANON
  t.lflag = t.lflag & ~termio.ECHO

  -- A read performed after select() reports readability may re-
  -- turn as soon as one byte is available.
  t.cc[termio.VMIN] = 1
  t.cc[termio.VTIME] = 0

  assert( tcsetattr( STDIN, termio.TCSANOW, t ) )

  initialized = true
end

function M.restore()
  if not initialized then return end

  assert( tcsetattr( STDIN, termio.TCSANOW, original_termios ) )

  initialized = false
end

-----------------------------------------------------------------
-- Terminal size.
-----------------------------------------------------------------
function M.size()
  local ws = assert( tcgetwinsize( STDOUT ) )
  return ws.row, ws.col
end

-----------------------------------------------------------------
-- Raw output.
-----------------------------------------------------------------
function M.write( s ) return write_all( STDOUT, s ) end

-----------------------------------------------------------------
-- Output buffer.
-----------------------------------------------------------------
local Buffer = {}
Buffer.__index = Buffer

function M.buffer() return setmetatable( {}, Buffer ) end

function Buffer:append( s )
  self[#self + 1] = s
  return self
end

function Buffer:text( s )
  self[#self + 1] = s
  return self
end

-----------------------------------------------------------------
-- Cursor movement.
-----------------------------------------------------------------
function Buffer:move_to( row, col )
  self[#self + 1] = CSI .. row .. ';' .. col .. 'H'
  return self
end

function Buffer:move_up( n )
  self[#self + 1] = CSI .. (n or 1) .. 'A'
  return self
end

function Buffer:move_down( n )
  self[#self + 1] = CSI .. (n or 1) .. 'B'
  return self
end

function Buffer:move_right( n )
  self[#self + 1] = CSI .. (n or 1) .. 'C'
  return self
end

function Buffer:move_left( n )
  self[#self + 1] = CSI .. (n or 1) .. 'D'
  return self
end

-----------------------------------------------------------------
-- Clearing.
-----------------------------------------------------------------
function Buffer:clear()
  self[#self + 1] = CSI .. '2J'
  return self
end

function Buffer:clear_to_end()
  self[#self + 1] = CSI .. '0J'
  return self
end

function Buffer:clear_line()
  self[#self + 1] = CSI .. '2K'
  return self
end

function Buffer:clear_to_eol()
  self[#self + 1] = CSI .. '0K'
  return self
end

-----------------------------------------------------------------
-- Cursor visibility.
-----------------------------------------------------------------
function Buffer:hide_cursor()
  self[#self + 1] = CSI .. '?25l'
  return self
end

function Buffer:show_cursor()
  self[#self + 1] = CSI .. '?25h'
  return self
end

-----------------------------------------------------------------
-- Alternate screen.
-----------------------------------------------------------------
function Buffer:alt_screen_on()
  self[#self + 1] = CSI .. '?1049h'
  return self
end

function Buffer:alt_screen_off()
  self[#self + 1] = CSI .. '?1049l'
  return self
end

-----------------------------------------------------------------
-- Text attributes.
-----------------------------------------------------------------
function Buffer:reset()
  self[#self + 1] = CSI .. '0m'
  return self
end

function Buffer:bold()
  self[#self + 1] = CSI .. '1m'
  return self
end

function Buffer:dim()
  self[#self + 1] = CSI .. '2m'
  return self
end

function Buffer:underline()
  self[#self + 1] = CSI .. '4m'
  return self
end

function Buffer:reverse()
  self[#self + 1] = CSI .. '7m'
  return self
end

function Buffer:fg( r, g, b )
  self[#self + 1] =
      CSI .. '38;2;' .. r .. ';' .. g .. ';' .. b .. 'm'
  return self
end

function Buffer:bg( r, g, b )
  self[#self + 1] =
      CSI .. '48;2;' .. r .. ';' .. g .. ';' .. b .. 'm'
  return self
end

-----------------------------------------------------------------
-- Synchronized output.
-----------------------------------------------------------------
function Buffer:sync_begin()
  self[#self + 1] = CSI .. '?2026h'
  return self
end

function Buffer:sync_end()
  self[#self + 1] = CSI .. '?2026l'
  return self
end

-----------------------------------------------------------------
-- Buffer handling.
-----------------------------------------------------------------
function Buffer:clear_buffer()
  for i = #self, 1, -1 do self[i] = nil end
  return self
end

function Buffer:string() return table.concat( self ) end

function Buffer:flush()
  local s = table.concat( self )

  -- Clear before writing so the buffer is also empty if write()
  -- subsequently throws/returns an error.
  self:clear_buffer()

  return write_all( STDOUT, s )
end

-----------------------------------------------------------------
-- Input buffering.
-----------------------------------------------------------------
local input = ''

-- Time at which an incomplete leading ESC was first observed.
local esc_started = nil

-----------------------------------------------------------------
-- Known escape sequences.
-----------------------------------------------------------------
local escape_keys = {
  ['\27[A']='UP',
  ['\27[B']='DOWN',
  ['\27[C']='RIGHT',
  ['\27[D']='LEFT',

  ['\27[H']='HOME',
  ['\27[F']='END',

  ['\27[1~']='HOME',
  ['\27[2~']='INSERT',
  ['\27[3~']='DELETE',
  ['\27[4~']='END',
  ['\27[5~']='PAGEUP',
  ['\27[6~']='PAGEDOWN',
  ['\27[7~']='HOME',
  ['\27[8~']='END',

  -- Common xterm function-key sequences.
  ['\27OP']='F1',
  ['\27OQ']='F2',
  ['\27OR']='F3',
  ['\27OS']='F4',

  ['\27[15~']='F5',
  ['\27[17~']='F6',
  ['\27[18~']='F7',
  ['\27[19~']='F8',
  ['\27[20~']='F9',
  ['\27[21~']='F10',
  ['\27[23~']='F11',
  ['\27[24~']='F12',
}

-----------------------------------------------------------------
-- Input reading.
-----------------------------------------------------------------
-- Call this ONLY after select()/poll() reports stdin as readable.
--
-- read() itself is therefore not being used as the readiness
-- mechanism. It merely consumes a chunk that we already know has
-- at least one byte available.
function M.read_input()
  local s, err = read( STDIN, 4096 )
  if not s then return nil, err end
  if s == '' then return false end

  input = input .. s

  return true
end

-----------------------------------------------------------------
-- Input parsing.
-----------------------------------------------------------------
local function consume( n )
  local res = input:sub( 1, n )
  input = input:sub( n + 1 )
  return res
end

local function is_prefix_of_known_sequence( s )
  for seq in pairs( escape_keys ) do
    if seq:sub( 1, #s ) == s then return true end
  end

  return false
end

-- Return one decoded key if one is currently available.
--
-- This function NEVER performs a read and NEVER blocks.
--
-- Returns nil if:
--
--   * no input is buffered; or
--   * an ESC prefix might still be receiving more bytes.
function M.getkey()
  if #input == 0 then
    esc_started = nil
    return nil
  end

  ---------------------------------------------------------------
  -- Normal byte.
  ---------------------------------------------------------------
  if input:byte( 1 ) ~= 27 then
    esc_started = nil
    return consume( 1 )
  end

  ---------------------------------------------------------------
  -- ESC.
  ---------------------------------------------------------------
  -- First check for a complete known sequence.
  for seq, key in pairs( escape_keys ) do
    if input:sub( 1, #seq ) == seq then
      consume( #seq )
      esc_started = nil
      return key
    end
  end

  ---------------------------------------------------------------
  -- Is what we have so far potentially the beginning of one?
  ---------------------------------------------------------------
  if is_prefix_of_known_sequence( input ) then
    if not esc_started then esc_started = monotonic_seconds() end

    if monotonic_seconds() - esc_started < ESC_TIMEOUT then
      return nil
    end
  end

  ---------------------------------------------------------------
  -- Standalone ESC.
  ---------------------------------------------------------------
  consume( 1 )
  esc_started = nil
  return 'ESC'
end

-----------------------------------------------------------------
-- Queries.
-----------------------------------------------------------------
function M.has_input() return #input > 0 end

-----------------------------------------------------------------
-- Convenience lifecycle.
-----------------------------------------------------------------
function M.enter()
  M.init()

  local b = M.buffer()

  b:alt_screen_on():hide_cursor():clear():move_to( 1, 1 )

  return b:flush()
end

function M.leave()
  local b = M.buffer()

  b:reset():show_cursor():alt_screen_off()

  -- Do our best to restore termios even if output restoration fails.
  local ok, err = b:flush()

  M.restore()

  return ok, err
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return M