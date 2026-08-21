-----------------------------------------------------------------
-- Dump Contents of Redis DB.
-----------------------------------------------------------------
-- Pretty-print the contents of a redis DB.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local ru = require( 'redis-util' )

local printer = require( 'moon.printer' )
local color = require( 'moon.colors' )
local logger = require( 'moon.logger' )
local console = require( 'moon.console' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local info = assert( logger.info )
local clear_screen = assert( console.clear_screen )
local bar = assert( printer.bar )

local GREEN = assert( color.ANSI_GREEN )
local BLUE = assert( color.ANSI_BLUE )
local RED = assert( color.ANSI_RED )
local YELLOW = assert( color.ANSI_YELLOW )
local MAGENTA = assert( color.ANSI_MAGENTA )
-- local CYAN = assert( color.ANSI_CYAN )
local NORMAL = assert( color.ANSI_NORMAL )

local insert = table.insert
local format = string.format

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function has_control_chars( str )
  -- %c matches any control character
  return str:match( '%c' ) ~= nil
end

local function fmt_table( tbl )
  assert( type( tbl ) == 'table' )
  return printer.format_kv_table( tbl, {
    start='{\n  ' .. YELLOW,
    ending=BLUE .. '\n}' .. NORMAL,
    kv_sep=RED .. '=' .. MAGENTA,
    pair_sep='\n  ' .. YELLOW,
  } )
end

local function fmt_list( tbl )
  assert( type( tbl ) == 'table' )
  return printer.format_kv_table( tbl, {
    start='[\n  ' .. YELLOW,
    ending=BLUE .. '\n]' .. NORMAL,
    kv_sep=RED .. '=' .. MAGENTA,
    pair_sep='\n  ' .. YELLOW,
  } )
end

local function fmt_val( o )
  if type( o ) == 'table' then
    if o[1] then
      return fmt_list( o )
    else
      return fmt_table( o )
    end
  end
  local str = tostring( o )
  if not has_control_chars( str ) then
    return str
  else
    return format( '[binary:%d]', #str )
  end
end

local function get_key( cxn, key )
  local t = assert( cxn:type( key ) )
  if t == 'none' then return nil end
  if t == 'hash' then return cxn:hgetall( key ) end
  if t == 'string' then return cxn:get( key ) end
  if t == 'list' then return cxn:lrange( key, 0, -1 ) end
  error( 'unrecognized key type ' .. t .. ' for key=' .. key )
end

local function get_sorted_keys_by_type( cxn )
  local hashes = {}
  local strings = {}
  local lists = {}
  local keys = cxn:keys( '*' )
  table.sort( keys )
  for _, key in ipairs( keys ) do
    local val = get_key( cxn, key )
    local t = type( val )
    local o = { key=key, val=val }
    if t == 'table' and val[1] then
      insert( lists, o )
    elseif t == 'table' then
      insert( hashes, o )
    else
      insert( strings, o )
    end
  end
  return strings, lists, hashes
end

local function fmt_keyval( key, val )
  return format( '%s%s%s %s=>%s %s%s%s', --
  GREEN, key, NORMAL, --
  RED, NORMAL, --
  BLUE, fmt_val( val ), NORMAL --
   )
end

local function emit( what )
  if #what == 0 then return end
  for _, key_val in ipairs( what ) do
    print( fmt_keyval( key_val.key, key_val.val ) )
  end
end

local function key_from_channel( channel )
  assert( channel, 'invalid channel' )
  local key = channel:match( '__keyspace@0__:(.*)' )
  assert( key, 'unexpected channel format' )
  return key
end

local function dump( cxn )
  local strings, lists, hashes = get_sorted_keys_by_type( cxn )
  bar()
  emit( strings )
  emit( hashes )
  emit( lists )
end

local function watching_dump( cxn )
  -- We need to create a new connection for the subscription be-
  -- cause once we subscribe on a connection we're not allowed to
  -- send any other commands (and for that same reason, we don't
  -- put the new connection in a variable).
  local messages = assert( redist.connect() ):pubsub{
    psubscribe='__keyspace@0__:farm:*',
  }

  -- Note that the loop body will run immediately on the first
  -- iteration because we always get the first event immediately
  -- that merely tells us we've subscribed. In that case, the
  -- message.kind == 'psubscribe'.
  --
  -- `abort` is a function that we can call which will unsub-
  -- scribe and cause the loop to end.
  --
  --   message:        example:
  --   ----------------------------------------------------------
  --   kind            pmessage
  --   pattern         __keyspace@0__:farm:*
  --   channel         __keyspace@0__:farm:queue:compile:cpp*
  --   payload         rpush
  --
  for message, abort in messages do
    local key = key_from_channel( message.channel )
    clear_screen()
    info( format( 'key: %s', key ) )
    dump( cxn )
    if key == 'farm:watch:stop' then abort() end
  end

end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main( ... )
  local args = { ... }
  local arg1 = args[1]
  local watch = (arg1 == '--watch')

  local cxn = assert( ru.connect() )
  if not watch then
    dump( cxn )
  else
    watching_dump( cxn )
  end

  return 0
end

-----------------------------------------------------------------
-- Launch.
-----------------------------------------------------------------
os.exit( main( ... ) )