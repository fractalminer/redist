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

local logger = require( 'moon.logger' )
local time = require( 'moon.time' )
local zstd = require( 'moon.zstd' )

local zlib = require( 'zlib' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )
local timeit = assert( time.timeit_micros )

local format = assert( string.format )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function compress_zlib( what, level )
  local deflate = zlib.deflate( assert( level ) )
  return (deflate( what, 'finish' ))
end

local function decompress_zlib( what )
  local inflate = zlib.inflate()
  return (inflate( what ))
end

-- More advanced: faster and better compression.
local function compress_zstd( what, level )
  return zstd.compress( what, assert( level ) )
end

-- More advanced: faster and better compression.
local function decompress_zstd( what )
  return zstd.decompress( what )
end

local function compress( what )
  local method = config.general.COMPRESSION_METHOD
  local level = config.general.COMPRESSION_LEVEL
  local time_taken, compressed =
      timeit( function()
        if method == 'zlib' then
          return compress_zlib( what, level )
        elseif method == 'zstd' then
          return compress_zstd( what, level )
        else
          error(
              format( 'unrecognized compression type: %s', method ) )
        end
      end )
  debug( 'compression time: %d us', time_taken )
  return compressed
end

local function decompress( what )
  local method = config.general.COMPRESSION_METHOD
  local time_taken, decompressed =
      timeit( function()
        if method == 'zlib' then
          return decompress_zlib( what )
        elseif method == 'zstd' then
          return decompress_zstd( what )
        else
          error(
              format( 'unrecognized compression type: %s', method ) )
        end
      end )
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
