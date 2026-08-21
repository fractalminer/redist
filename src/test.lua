local ru = require( 'redis-util' )

local printer = require( 'moon.printer' )

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

local function make_hash_mt( cxn, key )
  return {
    __pairs=function( _ ) return pairs( cxn:hgetall( key ) ) end,
    __ipairs=function( _ ) return ipairs( cxn:hgetall( key ) ) end,
    __index=function( _, ht_key )
      return cxn:hget( key, ht_key )
    end,
    __newindex=function( _, ht_key, ht_val )
      if ht_val == nil then
        cxn:hdel( key, ht_key )
        return
      end
      cxn:hset( key, ht_key, ht_val )
    end,
  }
end

local function get_key( cxn, key )
  -- We're actually ending the chain and querying.
  if not cxn:exists( key ) then
    -- error( 'failed to get non-existent key ' .. key )
    return nil
  end
  local t = assert( cxn:type( key ) )
  if t == 'hash' then
    return setmetatable( {}, make_hash_mt( cxn, key ) )
  end
  if t == 'string' then return cxn:get( key ) end
  error( 'unrecognized key type ' .. t .. ' for key=' .. key )
end

local function set_key( cxn, key, val )
  local t = type( val )
  if t == 'string' or t == 'number' then
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

local function del_key( cxn, key )
  local t = type( key )
  if t == 'string' or t == 'number' then
    cxn:del( key )
    return
  end
  error( 'unhandled lua value type ' .. t )
end

local db_mt = {
  __index=function( tbl, key ) return get_key( tbl.cxn, key ) end,
  __newindex=function( tbl, key, val )
    if val == nil then
      del_key( tbl.cxn, key )
      return
    end
    set_key( tbl.cxn, key, val )
  end,
  __tostring=function( tbl )
    return 'redis database: #keys=' .. tbl.cxn:dbsize()
  end,
}

local function open_db()
  local cxn = assert( ru.connect() )
  assert( cxn:ping() )
  return setmetatable( { cxn=cxn }, db_mt )
end

local db = assert( open_db() )

local desc = { column_names={ 'value' }, row_names={}, data={} }

local function add( path, value )
  insert( desc.row_names, path )
  insert( desc.data, { tostring( value ) } )
end

db['one:two:three'] = 555
db['eight:nine'] = { foo='bar' }
db['eight:nine'].baz = 777
db['eight:nine'].bam = 'world'

print( fmt_table( db.cxn:hmget( 'eight:nine', 'baz', 'bam' ) ) )

assert( not db.zzz )
assert( not db['one:zzz'] )
assert( not db['eight:nine'].zzz )

add( 'db', db )
add( 'db["residents"]', db['residents'] )
add( 'db["residents:david"]', fmt_table( db['residents:david'] ) )
add( 'db["residents:david"].city', db['residents:david'].city )
add( 'db.aaa', db.aaa )
add( 'db["aaa:bbb"]', db['aaa:bbb'] )
add( 'db["aaa:bbb:ccc"]', db['aaa:bbb:ccc'] )
add( 'db["aaa:bbb:ccc:ddd"]', fmt_table( db['aaa:bbb:ccc:ddd'] ) )
add( 'db["aaa:bbb:ccc:ddd:n"]', db['aaa:bbb:ccc:ddd:n'] )
add( 'db["aaa:bbb:ccc:ddd"].n', db['aaa:bbb:ccc:ddd'].n )
add( 'db.age', db.age )
add( 'db["name:first"]', db['name:first'] )
add( 'db["name:last"]', db['name:last'] )
add( 'db["one:two:three"]', db['one:two:three'] )
assert( not db['one:two:three']['four'] )
db['eight:nine'].biff = nil
add( 'db["eight:nine"]', fmt_table( db['eight:nine'] ) )
add( 'db["eight:nine"].baz', db['eight:nine'].baz )
add( 'type( db["eight:nine"].baz )', type( db['eight:nine'].baz ) )
add( 'db["eight:nine"].bam', db['eight:nine'].bam )
db['eight:nine'].biff = 'hello'
add( 'db["eight:nine"]', fmt_table( db['eight:nine'] ) )
add( 'db["eight:nine"].biff', db['eight:nine'].biff )
assert( db['eight:nine'] )
db['eight:nine'] = nil
assert( not db['eight:nine'] )
add( 'db["eight:nine"]', tostring( db['eight:nine'] ) )

for _, row in ipairs( printer.format_data_table_rows( desc ) ) do
  print( row )
end