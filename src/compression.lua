-----------------------------------------------------------------
-- Data compression.
-----------------------------------------------------------------
-- Because ReDist needs to marshall large blobs (e.g. pre-
-- processed cpp files, object files, etc.) to and from Redis, it
-- benefits from a good compression algo.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local config = require( 'config' )

local freeze = require( 'moon.freeze' )
local logger = require( 'moon.logger' )
local time = require( 'moon.time' )
local zstd = require( 'moon.zstd' )

local zlib = require( 'zlib' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local harden = assert( freeze.harden )
local debug = assert( logger.debug )
local timeit = assert( time.timeit_micros )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function compress( what )
  assert( what )
  local level = config.compression.LEVEL
  local time_taken, compressed =
      timeit( function() return zstd.compress( what, level ) end )
  debug( 'compression time: %d us', time_taken )
  return compressed
end

local function decompress( what )
  local time_taken, decompressed =
      timeit( function() return zstd.decompress( what ) end )
  debug( 'decompression time: %d us', time_taken )
  return decompressed
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  compress=compress, --
  decompress=decompress, --
}
