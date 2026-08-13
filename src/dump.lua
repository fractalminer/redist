-----------------------------------------------------------------
-- Dump Contents of Redis DB.
-----------------------------------------------------------------
-- Pretty-print the contents of a redis DB.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local redist = require( 'redist' )

local printer = require( 'moon.printer' )
local color = require( 'moon.colors' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local title = assert( printer.title )

local GREEN = assert( color.ANSI_GREEN )
local BLUE = assert( color.ANSI_BLUE )
local RED = assert( color.ANSI_RED )
local YELLOW = assert( color.ANSI_YELLOW )
local MAGENTA = assert( color.ANSI_MAGENTA )
local CYAN = assert( color.ANSI_CYAN )
local NORMAL = assert( color.ANSI_NORMAL )

local insert = table.insert
local format = string.format

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
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
  return tostring( o )
end

local function get_key( cxn, key )
  local t = assert( cxn:type( key ) )
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

local function emit( name, what )
  io.write( CYAN )
  title( name, '=' )
  io.write( NORMAL )
  for _, key_val in ipairs( what ) do
    print( fmt_keyval( key_val.key, key_val.val ) )
  end
  print()
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local cxn = assert( redist.connect() )

  local strings, lists, hashes = get_sorted_keys_by_type( cxn )

  emit( 'STRINGS', strings )
  emit( 'LISTS', lists )
  emit( 'HASHES', hashes )
end

-----------------------------------------------------------------
-- Launch.
-----------------------------------------------------------------
os.exit( main() )