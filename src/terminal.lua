---------------------------------------------------------------------
-- terminal.lua
--
-- Minimal terminal support using POSIX termios + ANSI escape
-- sequences. No curses.
---------------------------------------------------------------------
local M = {}

-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local termio = require( 'posix.termio' )
local unistd = require( 'posix.unistd' )

---------------------------------------------------------------------
-- File descriptors.
---------------------------------------------------------------------
local STDIN = unistd.STDIN_FILENO or 0
local STDOUT = unistd.STDOUT_FILENO or 1

---------------------------------------------------------------------
-- State.
---------------------------------------------------------------------
local original_termios = nil
local initialized = false

---------------------------------------------------------------------
-- Helpers.
---------------------------------------------------------------------
local function deep_copy( x )
  if type( x ) ~= 'table' then return x end

  local res = {}
  for k, v in pairs( x ) do res[k] = deep_copy( v ) end
  return res
end

local function write_all( fd, s )
  local offset = 0

  while offset < #s do
    local n, err = unistd.write( fd, s, #s - offset, offset )
    if not n then return nil, err end
    offset = offset + n
  end

  return true
end

---------------------------------------------------------------------
-- Terminal mode.
---------------------------------------------------------------------
function M.init()
  if initialized then return end

  original_termios = assert( termio.tcgetattr( STDIN ) )

  local t = deep_copy( original_termios )

  -- Non-canonical input:
  --
  --   * input becomes available immediately rather than waiting
  --     for Enter.
  --
  -- No echo:
  --
  --   * typed characters are not automatically printed.
  --
  -- Deliberately leave ISIG enabled so that Ctrl-C, Ctrl-Z, etc.
  -- retain their normal signal behavior.
  t.lflag = t.lflag & ~termio.ICANON
  t.lflag = t.lflag & ~termio.ECHO

  -- read() waits for at least one byte.
  t.cc[termio.VMIN] = 1
  t.cc[termio.VTIME] = 0

  assert( termio.tcsetattr( STDIN, termio.TCSANOW, t ) )

  initialized = true
end

function M.restore()
  if not initialized then return end

  assert( termio.tcsetattr( STDIN, termio.TCSANOW,
                            original_termios ) )

  initialized = false
end

---------------------------------------------------------------------
-- Terminal size.
---------------------------------------------------------------------
function M.size()
  local ws = assert( termio.tcgetwinsize( STDOUT ) )
  return ws.row, ws.col
end

---------------------------------------------------------------------
-- Raw output.
---------------------------------------------------------------------
function M.write( s ) return write_all( STDOUT, s ) end

---------------------------------------------------------------------
-- ANSI escape sequences.
---------------------------------------------------------------------
local ESC = '\27['

function M.move_to( row, col )
  -- ANSI coordinates are 1-based.
  return ESC .. row .. ';' .. col .. 'H'
end

function M.move_up( n ) return ESC .. (n or 1) .. 'A' end

function M.move_down( n ) return ESC .. (n or 1) .. 'B' end

function M.move_right( n ) return ESC .. (n or 1) .. 'C' end

function M.move_left( n ) return ESC .. (n or 1) .. 'D' end

function M.clear() return ESC .. '2J' end

function M.clear_to_end() return ESC .. '0J' end

function M.clear_line() return ESC .. '2K' end

function M.clear_to_eol() return ESC .. '0K' end

function M.hide_cursor() return ESC .. '?25l' end

function M.show_cursor() return ESC .. '?25h' end

function M.alt_screen_on() return ESC .. '?1049h' end

function M.alt_screen_off() return ESC .. '?1049l' end

function M.reset() return ESC .. '0m' end

function M.bold() return ESC .. '1m' end

function M.dim() return ESC .. '2m' end

function M.underline() return ESC .. '4m' end

function M.reverse() return ESC .. '7m' end

function M.fg( r, g, b )
  return ESC .. '38;2;' .. r .. ';' .. g .. ';' .. b .. 'm'
end

function M.bg( r, g, b )
  return ESC .. '48;2;' .. r .. ';' .. g .. ';' .. b .. 'm'
end

---------------------------------------------------------------------
-- Synchronized output.
--
-- Supported by many modern terminal emulators. The terminal holds
-- display updates between these sequences, avoiding partially drawn
-- frames.
---------------------------------------------------------------------
function M.sync_begin() return ESC .. '?2026h' end

function M.sync_end() return ESC .. '?2026l' end

---------------------------------------------------------------------
-- Input.
---------------------------------------------------------------------
-- Translate the common ANSI escape sequences into the names that
-- minicurses.getkey() returned.
local escape_keys = {
  ['\27[A']='UP',
  ['\27[B']='DOWN',
  ['\27[C']='RIGHT',
  ['\27[D']='LEFT',

  ['\27[H']='HOME',
  ['\27[F']='END',

  ['\27[2~']='INSERT',
  ['\27[3~']='DELETE',
  ['\27[5~']='PAGEUP',
  ['\27[6~']='PAGEDOWN',
}

-- Read one key.
--
-- IMPORTANT: the caller should only invoke this after select()/poll()
-- has indicated that stdin is readable.
--
-- For ordinary characters this returns the character.
-- For recognized escape sequences it returns strings such as
-- "UP", "DOWN", etc.
function M.getkey()
  local first, err = unistd.read( STDIN, 1 )
  if not first then return nil, err end
  if first == '' then return nil end

  if first ~= '\27' then return first end

  -------------------------------------------------------------------
  -- Escape sequence.
  --
  -- At this point we need to see whether more bytes immediately
  -- follow ESC. The simplest version blocks for the remainder just
  -- like minicurses.getkey().
  --
  -- This deliberately preserves minicurses' basic behavior for now.
  -------------------------------------------------------------------

  local second, err = unistd.read( STDIN, 1 )
  if not second then return nil, err end

  if second ~= '[' then
    -- Alt-x and similar sequences. For compatibility with minicurses,
    -- just return the character following ESC.
    return second
  end

  local third, err = unistd.read( STDIN, 1 )
  if not third then return nil, err end

  local seq = '\27[' .. third

  -- Simple 3-byte sequences: ESC [ A, etc.
  local key = escape_keys[seq]
  if key then return key end

  -- Tilde-terminated sequences: ESC [ 2 ~, etc.
  if third:match '%d' then
    local fourth, err = unistd.read( STDIN, 1 )
    if not fourth then return nil, err end

    seq = seq .. fourth

    key = escape_keys[seq]
    if key then return key end
  end

  -- Unknown escape sequence.
  return seq
end

---------------------------------------------------------------------
-- Convenience lifecycle.
---------------------------------------------------------------------
function M.enter()
  M.init()

  assert( M.write( M.alt_screen_on() .. M.hide_cursor() ..
                       M.clear() .. M.move_to( 1, 1 ) ) )
end

function M.leave()
  -- Restore visible terminal state before restoring termios.
  M.write( M.reset() .. M.show_cursor() .. M.alt_screen_off() )

  M.restore()
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return M