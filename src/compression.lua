-----------------------------------------------------------------
-- Data compression.
-----------------------------------------------------------------
-- Because ReDist needs to marshall large blobs (e.g. pre-
-- processed cpp files, object files, etc.) to and from Redis, it
-- benefits from a good compression algo.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local logger = require( 'moon.logger' )
local time = require( 'moon.time' )
local zstd = require( 'moon.zstd' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )
local tcall = assert( time.tcall )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function compress( what, level )
  assert( what )
  assert( level, 'missing compression level' )
  assert( type( level ) == 'number' )
  local label = format( 'compression|%d', level )
  return tcall( debug, label, zstd.compress, what, level )
end

local function decompress( what )
  assert( what )
  return tcall( debug, 'decompression', zstd.decompress, what )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  compress=compress, --
  decompress=decompress, --
}
