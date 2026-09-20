local logger = require( 'moon.logger' )

logger.level = logger.levels.DEBUG

local lcache = require 'lcache'
local lc<close> = lcache.open()

lc:blob_set( 'hello' )
lc:blob_set( 'world' )

-- for row in lc.db:nrows( 'SELECT * from blob' ) do
--   print( table.unpack( row ) )
-- end

print( 1, lc:blob_get( 'jjj' ) )
print( 2, lc:blob_get( '47f3450b588f14654aa791b4abe4726f' ) )
print( 3, lc:blob_get( '6119af7840b4bcb774ec6c6e1737b3a5' ) )

lc:evict()
lc:evict()
lc:evict()

print( 1, lc:blob_get( 'jjj' ) )
print( 2, lc:blob_get( '47f3450b588f14654aa791b4abe4726f' ) )
print( 3, lc:blob_get( '6119af7840b4bcb774ec6c6e1737b3a5' ) )