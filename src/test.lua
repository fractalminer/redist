local printer = require( 'moon.printer' )
local redis = require( 'redis' )

local HOST = 'bonobo'
local PORT = 6380

local insert = table.insert

local function fmt_table( tbl )
  assert( type( tbl ) == 'table' )
  return printer.format_kv_table( tbl, {
    start='[',
    ending=']',
    kv_sep='=',
    pair_sep='|',
  } )
end

local function print_table( tbl ) print( fmt_table( tbl ) ) end

local make_keybuilder

local function make_hash_mt( cxn, key )
  return {
    __newindex=function( tbl, ht_key, ht_val )
      cxn:hset( key, ht_key, ht_val )
      rawset( tbl, ht_key, ht_val )
    end,
  }
end

local function get_key( cxn, key )
  -- We're actually ending the chain and querying.
  if not cxn:exists( key ) then
    error( 'failed to get non-existent key ' .. key )
  end
  local t = assert( cxn:type( key ) )
  if t == 'hash' then
    local hash_mt = make_hash_mt( cxn, key )
    return setmetatable( cxn:hgetall( key ), hash_mt )
  end
  if t == 'string' then return cxn:get( key ) end
  error( 'unrecognized key type ' .. t .. ' for key=' .. key )
end

local function set_key( cxn, key, val )
  local t = type( val )
  if t == 'string' then
    cxn:set( key, key, val )
    return
  end
  if t == 'number' then
    cxn:set( key, val )
    return
  end
  if t == 'table' then
    for k, v in pairs( val ) do
      assert( type( v ) == 'number' or type( v ) == 'string' )
      cxn:hset( key, k, tostring( v ) )
    end
    return
  end
  error( 'unhandled lua value type ' .. t )
end

local keybuilder_mt = {
  __index=function( tbl, next )
    local cxn = assert( rawget( tbl, 'cxn' ) )
    local key = rawget( tbl, 'key' )
    return make_keybuilder( cxn, key, next )
  end,
  __newindex=function( tbl, next, val )
    local cxn = assert( rawget( tbl, 'cxn' ) )
    local key = rawget( tbl, 'key' )
    set_key( cxn, key .. ':' .. next, val )
  end,
  __tostring=function( tbl )
    local key = rawget( tbl, 'key' )
    return '<key builder: key=' .. key .. '>'
  end,
}

function make_keybuilder( cxn, start, next )
  assert( start )
  assert( type( start ) == 'string' )
  local o = {}
  o.cxn = cxn
  o.key = start
  if next then o.key = o.key .. ':' .. next end
  if cxn:exists( o.key ) then return get_key( cxn, o.key ) end
  return setmetatable( o, keybuilder_mt )
end

local db_mt = {
  __index=function( tbl, key )
    return make_keybuilder( tbl.cxn, key )
  end,
  __newindex=function( tbl, key, val )
    set_key( tbl.cxn, key, val )
  end,
  __tostring=function( tbl )
    return 'redis database: #keys=' .. tbl.cxn:dbsize()
  end,
}

local function create_db( cxn )
  local o = { cxn=cxn }
  return setmetatable( o, db_mt )
end

local function open_db( host, port )
  ---@diagnostic disable-next-line: param-type-mismatch
  local cxn = assert( redis.connect( host, port ) )
  assert( cxn:ping() )
  local db = create_db( cxn )
  return db
end

local db = open_db( HOST, PORT )

local desc = { column_names={ 'value' }, row_names={}, data={} }

local function add( path, value )
  insert( desc.row_names, path )
  insert( desc.data, { value } )
end

db.one.two.three = 555
db.eight.nine = { foo='bar' }
db.eight.nine.baz = 777

add( 'db', db )
add( 'db.residents', db.residents )
add( 'db.residents.david', fmt_table( db.residents.david ) )
add( 'db.residents.david.city', db.residents.david.city )
add( 'db.aaa', db.aaa )
add( 'db.aaa.bbb', db.aaa.bbb )
add( 'db.aaa.bbb.ccc', db.aaa.bbb.ccc )
add( 'db.aaa.bbb.ccc.ddd', fmt_table( db.aaa.bbb.ccc.ddd ) )
add( 'db.aaa.bbb.ccc.ddd.n', db.aaa.bbb.ccc.ddd.n )
add( 'db.age', db.age )
add( 'db["name:first"]', db.name.first )
add( 'db["name:last"]', db.name.last )
add( 'db.one.two.three', db.one.two.three )
assert( not db.one.two.three['four'] )
add( 'db.eight.nine', fmt_table( db.eight.nine ) )
add( 'db.eight.nine.baz', db.eight.nine.baz )
db.eight.nine.biff = 'hello'
add( 'db.eight.nine', fmt_table( db.eight.nine ) )
add( 'db.eight.nine.biff', db.eight.nine.biff )

for _, row in ipairs( printer.format_data_table_rows( desc ) ) do
  print( row )
end