-----------------------------------------------------------------
-- SQLite helper.
-----------------------------------------------------------------
local sqlite3 = require( 'lsqlite3' )

local logger = require( 'moon.logger' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local info = assert( logger.debug )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function connect( db_path )
  info( 'opening sqlite db %s', db_path )
  local db = assert( sqlite3.open( db_path ) )
  assert( db:exec( [[
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    PRAGMA busy_timeout=5000;
  ]] ) == sqlite3.OK )
  return db
end

local function get_error( db )
  local err_code = db:errcode()
  local err_msg = db:errmsg()
  return format( 'sqlite error: [%d] %s', err_code, err_msg )
end

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return {
  connect=connect,
  get_error=get_error,
  OK=assert( sqlite3.OK ),
  DONE=assert( sqlite3.DONE ),
  ERROR=assert( sqlite3.ERROR ),
  MISUSE=assert( sqlite3.MISUSE ),
  ROW=assert( sqlite3.ROW ),
}
