-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local logger = require( 'moon.logger' )

local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local dbg = assert( logger.dbg )

local dns = assert( socket.dns )

local format = assert( string.format )

-----------------------------------------------------------------
-- Global state.
-----------------------------------------------------------------
-- Caches for these values since they are not expected to change.
local MACHINE_ID = nil
local HOSTNAME = nil
local MACHINE_LABEL = nil

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function machine_id()
  if MACHINE_ID then return MACHINE_ID end
  local f<close> = assert( io.open( '/etc/machine-id' ) )
  local id = assert( f:read( 'l*' ) )
  assert( #id == 32 )
  MACHINE_ID = id
  -- This log is basically to notify on a cache miss.
  dbg( 'reading machine ID: %s', id )
  return id
end

local function hostname()
  if HOSTNAME then return HOSTNAME end
  local name = assert( dns.gethostname() )
  assert( type( name ) == 'string',
          'unexpected type for hostname: ' .. type( name ) )
  assert( #name > 0, 'hostname empty' )
  HOSTNAME = name
  -- This log is basically to notify on a cache miss.
  dbg( 'reading hostname: %s', name )
  return name
end

-- This one can be used as a unique identifier for this host that
-- is also human readable because it starts with the hostname.
-- But it also has the machine ID just in the event that two
-- hosts have the same hostname.
local function machine_label()
  if MACHINE_LABEL then return MACHINE_LABEL end
  MACHINE_LABEL = format( '%s-%s', hostname(), machine_id() )
  return MACHINE_LABEL
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  machine_id=machine_id, --
  hostname=hostname, --
  machine_label=machine_label, --
}
