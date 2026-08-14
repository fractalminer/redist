-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local redist = require( 'redist' )

local printer = require( 'moon.printer' )

local posix = require( 'posix' )
local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local dns = assert( socket.dns )

-- local print_list = assert( printer.print_list )

local format = string.format
local insert = table.insert
local unpack = table.unpack

-----------------------------------------------------------------
-- Constants.
-----------------------------------------------------------------
local POLL_TIMEOUT = 1
local EXPIRE_ADVERTISE = 5

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
local PID = assert( posix.getpid().pid )

local HOSTNAME = assert( dns.gethostname() )

local STATE = {
  status='idle', --
  task=nil, --
}

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function set_hash( cxn, key, tbl, expiry )
  assert( type( tbl ) == 'table' )
  local args = {}
  for k, v in pairs( tbl ) do
    insert( args, k )
    insert( args, v )
  end
  cxn:transaction( function( t )
    t:del( key )
    t:hset( key, unpack( args ) )
    if expiry then t:expire( key, expiry ) end
  end )
end

local function advertise( cxn )
  local key = format( 'farm:worker:%s:%s', HOSTNAME, PID )
  set_hash( cxn, key, {
    hostname=HOSTNAME, --
    pid=PID, --
    status=STATE.status, --
    task=STATE.task, --
  }, EXPIRE_ADVERTISE )
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local cxn = assert( redist.connect() )

  while true do
    advertise( cxn )
    print( 'waiting...' )
    local o = cxn:blpop( 'nolist', POLL_TIMEOUT )
    if o then print( o[2] ) end
  end
end

main()