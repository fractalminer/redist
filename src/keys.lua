-----------------------------------------------------------------
-- Redis Key Maker.
-----------------------------------------------------------------
local M = {}

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local unpack = assert( table.unpack )

local NS = 'farm'

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function make( key, elems )
  assert( type( elems ) == 'table' )
  return assert( key ):format( unpack( elems ) )
end

function M.ns()
  local key = '%s'
  local elems = {
    NS, --
  }
  return make( key, elems )
end

function M.queue()
  local key = '%s:queue'
  local elems = {
    M.ns(), --
  }
  return make( key, elems )
end

function M.remote_queue( which )
  local key = '%s:remote:%s'
  local elems = {
    M.queue(), --
    assert( which ), --
  }
  return make( key, elems )
end

function M.global_remote_compile_queue()
  return M.remote_queue( 'global' )
end

function M.host_remote_compile_queue( label )
  return M.remote_queue( label )
end

function M.local_queue( label )
  local key = '%s:local:%s'
  local elems = {
    M.queue(), --
    assert( label ), --
  }
  return make( key, elems )
end

function M.logs()
  local key = '%s:log'
  local elems = {
    M.ns(), --
  }
  return make( key, elems )
end

function M.queue_log()
  local key = '%s:queues'
  local elems = {
    M.logs(), --
  }
  return make( key, elems )
end

function M.workers()
  local key = '%s:worker'
  local elems = {
    M.ns(), --
  }
  return make( key, elems )
end

function M.worker_advertisement( label, pid )
  local key = '%s:%s:%s'
  local elems = {
    M.workers(), --
    assert( label ), --
    assert( pid ), --
  }
  return make( key, elems )
end

function M.nodes()
  local key = '%s:node'
  local elems = {
    M.ns(), --
  }
  return make( key, elems )
end

function M.node( label )
  local key = '%s:node:%s'
  local elems = {
    M.ns(), --
    assert( label ), --
  }
  return make( key, elems )
end

function M.node_stats( label )
  local key = '%s:node:stats'
  local elems = {
    M.node( label ), --
  }
  return make( key, elems )
end

function M.node_manager_advertisement( label )
  local key = '%s:presence:manager'
  local elems = {
    M.node( label ), --
  }
  return make( key, elems )
end

function M.task( hash )
  local key = '%s:task:%s'
  local elems = {
    M.ns(), --
    assert( hash ), --
  }
  return make( key, elems )
end

function M.task_input( hash )
  local key = '%s:input'
  local elems = {
    M.task( hash ), --
  }
  return make( key, elems )
end

function M.task_output( hash )
  local key = '%s:output'
  local elems = {
    M.task( hash ), --
  }
  return make( key, elems )
end

function M.events()
  local key = '%s:events'
  local elems = {
    M.ns(), --
  }
  return make( key, elems )
end

function M.task_events()
  local key = '%s:task'
  local elems = {
    M.events(), --
  }
  return make( key, elems )
end

function M.blobs()
  local key = '%s:blob'
  local elems = {
    M.ns(), --
  }
  return make( key, elems )
end

function M.blob( hash )
  local key = '%s:%s'
  local elems = {
    M.blobs(), --
    assert( hash ), --
  }
  return make( key, elems )
end

function M.worker_presence_set( node, set )
  local key = '%s:presence:%s'
  local elems = {
    M.node( node ), --
    assert( set ), --
  }
  return make( key, elems )
end

function M.node_worker_target_count( node, label )
  local key = '%s:target_count:%s'
  local elems = {
    M.node( node ), --
    assert( label ), --
  }
  return make( key, elems )
end

-----------------------------------------------------------------
-- Module..
-----------------------------------------------------------------
return M
