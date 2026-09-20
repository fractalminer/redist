-----------------------------------------------------------------
-- Cache on local disk (sqlite).
-----------------------------------------------------------------
local config = require( 'config' )
local sqlite = require( 'sqlite' )
local hasher = assert( require( 'hash' ).hash )

local logger = require( 'moon.logger' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local err = assert( logger.err )
local debug = assert( logger.debug )

-----------------------------------------------------------------
-- Schema.
-----------------------------------------------------------------
local SCHEMA = [[
  PRAGMA journal_mode=WAL;
  PRAGMA synchronous=NORMAL;
  PRAGMA busy_timeout=5000;

  CREATE TABLE IF NOT EXISTS blob (
    hash        TEXT PRIMARY KEY,
    data        BLOB NOT NULL,
    size        INTEGER NOT NULL,
    last_used   INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS blob_lru
      ON blob( last_used );

  CREATE TABLE IF NOT EXISTS preprocessed (
      tu_key       TEXT PRIMARY KEY,
      content_hash TEXT NOT NULL
  );
]]

-----------------------------------------------------------------
-- Queries.
-----------------------------------------------------------------
local QUERY_BLOB_GET = [[
  SELECT data FROM blob WHERE hash=?
]]

local QUERY_BLOB_SET = [[
  INSERT OR IGNORE INTO
    blob( hash, data, size, last_used )
  VALUES
    (?, ?, ?, ?)
]]

local QUERY_PREPROCESSED = [[
  SELECT content_hash FROM preprocessed WHERE tu_key=?
]]

local QUERY_UPDATE_PREPROCESSED = [[
  INSERT INTO preprocessed( tu_key, content_hash )
  VALUES (?, ?)
  ON CONFLICT( tu_key ) DO UPDATE
  SET content_hash = excluded.content_hash;
]]

-- Evict old blobs that cause the total cache size to exceed a
-- certain threshold.
local QUERY_EVICT = [[
  WITH ranked AS (
      SELECT
          hash,
          SUM( size ) OVER (
              ORDER BY last_used DESC, hash
          ) AS cumulative_size
      FROM blob
  )
  DELETE FROM blob
  WHERE hash IN (
      SELECT hash
      FROM ranked
      WHERE cumulative_size > ?
  );
]]

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local LocalCache = {}
LocalCache.__index = LocalCache

function LocalCache:check_ok( code )
  if code == sqlite.OK then return true end
  local reason = sqlite.get_error( self.db )
  err( '%s', reason )
  error( reason )
end

function LocalCache:blob_get( hash )
  local stmt = assert( self.stmt.blob_get )
  stmt:reset()
  self:check_ok( stmt:bind_values( hash ) )
  local data
  if stmt:step() == sqlite.ROW then data = stmt:get_value( 0 ) end
  stmt:reset()
  return {
    hash=hash, --
    compressed=true, -- FIXME: shouldn't assume this.
    data=data, --
  }
end

function LocalCache:blob_set( blob )
  assert( blob )
  local data = assert( blob.data )
  local hash = assert( blob.hash )
  assert( type( data ) == 'string' )
  assert( type( hash ) == 'string' )
  local stmt = assert( self.stmt.blob_set )
  stmt:reset()
  self:check_ok( stmt:bind( 1, hash ) )
  self:check_ok( stmt:bind_blob( 2, data ) )
  self:check_ok( stmt:bind( 3, #data ) )
  self:check_ok( stmt:bind( 4, 0 ) )
  assert( stmt:step() == sqlite.DONE )
  stmt:reset()
end

function LocalCache:preprocessed_get( tu_key )
  local stmt = assert( self.stmt.preprocessed_get )
  stmt:reset()
  self:check_ok( stmt:bind_values( tu_key ) )
  local content_hash
  if stmt:step() == sqlite.ROW then
    content_hash = stmt:get_value( 0 )
  end
  stmt:reset()
  return content_hash
end

function LocalCache:preprocessed_update( tu_key, content_hash )
  local stmt = assert( self.stmt.preprocessed_update )
  stmt:reset()
  self:check_ok( stmt:bind_values( tu_key, content_hash ) )
  assert( stmt:step() == sqlite.DONE )
  stmt:reset()
end

function LocalCache:evict()
  local stmt = assert( self.stmt.evict )
  stmt:reset()
  self:check_ok( stmt:bind_values(
                     config.local_cache.MAX_SIZE_BYTES ) )
  assert( stmt:step() == sqlite.DONE )
  stmt:reset()
end

function LocalCache:init()
  self:check_ok( self.db:exec( SCHEMA ) )

  local queries = {
    blob_get=QUERY_BLOB_GET,
    blob_set=QUERY_BLOB_SET,
    preprocessed_get=QUERY_PREPROCESSED,
    preprocessed_update=QUERY_UPDATE_PREPROCESSED,
    evict=QUERY_EVICT,
  }

  self.stmt = {}
  for name, q in pairs( queries ) do
    self.stmt[name] = assert( self.db:prepare( q ) )
  end
end

function LocalCache:__close()
  for name, stmt in pairs( self.stmt ) do
    debug( 'releasing sqlite stmt %s', name )
    stmt:reset()
    stmt:finalize()
  end
end

local function open()
  local o = {}
  o.db = assert( sqlite.connect( config.local_cache.LOCATION ) )
  local res = setmetatable( o, LocalCache )
  res:init()
  return res
end

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return {
  LocalCache=open, --
}
