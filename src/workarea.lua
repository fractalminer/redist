-----------------------------------------------------------------
-- Helpers for temporary files in the workarea.
-----------------------------------------------------------------
local file = require( 'moon.file' )
local logger = require( 'moon.logger' )
local mcleanup = require( 'moon.cleanup' )
local str = require( 'moon.str' )

local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local cleanup = assert( mcleanup.cleanup )
local err = assert( logger.err )
local debug = assert( logger.debug )
local exists = assert( file.exists )
local is_path_absolute = assert( file.is_path_absolute )
local trace = assert( logger.trace )
local trim = assert( str.trim )

local dirname = assert( posix.dirname )
local rmdir = assert( posix.rmdir )

local format = assert( string.format )
local insert = assert( table.insert )

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
-- Returns a closable value.
local function rm_file_on_close( fname )
  assert( type( fname ) == 'string' )
  return cleanup( function()
    if not exists( fname ) then return end
    trace( 'removing temporary file: ' .. fname )
    local ok = os.remove( fname )
    -- Since we're already in a __close method here we'll just
    -- log the error.
    if not ok then err( 'failed to remove file: %s', fname ) end
  end )
end

local function rm_tmp_folders( prefix, dirs )
  debug( 'cleaning up folder %s', dirs )
  assert( dirs and #dirs > 0 )
  assert( is_path_absolute( prefix ) )
  assert( prefix:match( '^/tmp/' ) )
  local to_delete = {}
  dirs = trim( dirs )
  assert( dirs ~= '..' )
  if not is_path_absolute( dirs ) then dirs = '/' .. dirs end
  while dirs ~= '/' do
    assert( not dirs:match( '//' ) )
    insert( to_delete, format( '%s%s', prefix, dirs ) )
    dirs = dirname( dirs )
  end
  for _, dir in ipairs( to_delete ) do
    assert( dir:match( '^/tmp/' ), dir )
    trace( 'deleting: %s', dir )
    if exists( dir ) then rmdir( dir ) end
  end
end

local function rm_tmp_folders_on_close( prefix, dirs )
  assert( type( prefix ) == 'string' )
  assert( type( dirs ) == 'string' )
  assert( is_path_absolute( prefix ) )
  assert( prefix:match( '^/tmp/farm/workarea' ) )
  return cleanup( function() rm_tmp_folders( prefix, dirs ) end )
end

-----------------------------------------------------------------
-- Finished.
-----------------------------------------------------------------
return {
  rm_file_on_close=rm_file_on_close,
  rm_tmp_folders_on_close=rm_tmp_folders_on_close,
}
