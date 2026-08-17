-- Compile Command Parser.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local str = require( 'moon.str' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local trim = assert( str.trim )

local insert = table.insert
local format = string.format

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function cdecode( cmd )
  assert( type( cmd ) == 'string' )
  cmd = trim( cmd )
  local elems = cmd:split( '%s+' )
  local i = 1
  local decoded = {
    compiler=nil,
    flags={},
    preprocess=nil,
    compile=nil,
    output=nil,
    object_files=nil,
  }
  while true do
    if not elems[i] then break end
    local l, r = elems[i], elems[i + 1]
    local ok = true
    local reason
    local function key_val( where )
      if not r then
        return false,
               'invalid command line: missing argument to ' .. l
      end
      if decoded[where] then
        return false, 'invalid command line: multiple ' .. l
      end
      decoded[where] = r
      i = i + 2
      return true
    end
    if i == 1 then
      if l:match( '^-' ) then
        ok, reason = false, 'missing compiler in compile command'
      else
        decoded.compiler = l
        ok = true
      end
      i = i + 1
    elseif l == '-E' then
      ok, reason = key_val( 'preprocess' )
    elseif l == '-c' then
      ok, reason = key_val( 'compile' )
    elseif l == '-o' then
      ok, reason = key_val( 'output' )
    else
      if l:sub( 1, 1 ) == '-' then
        insert( decoded.flags, l )
        ok = true
      elseif l:sub( -2, -1 ) == '.o' then
        decoded.object_files = decoded.object_files or {}
        insert( decoded.object_files, l )
        ok = true
      else
        ok = false
        reason = format( 'unrecognized argument form: %s', l )
      end
      i = i + 1
    end
    if not ok then return ok, reason end
  end
  if decoded.compile and decoded.preprocess then
    return false, 'cannot have both -c and -E'
  end
  if decoded.compile and decoded.object_files then
    return false, 'cannot have both -c and object files'
  end
  if decoded.preprocess and decoded.object_files then
    return false, 'cannot have both -E and object files'
  end
  return decoded
end

local function cencode( o )
  local elems = {}
  local function add( what ) insert( elems, what ) end
  if o.compiler then add( o.compiler ) end
  for _, flag in ipairs( o.flags ) do add( flag ) end
  if o.preprocess then
    add( '-E' )
    add( o.preprocess )
  end
  if o.object_files then
    for _, ofile in ipairs( o.object_files ) do add( ofile ) end
  end
  if o.compile then
    add( '-c' )
    add( o.compile )
  end
  if o.output then
    add( '-o' )
    add( o.output )
  end
  -- Return as a list to give the caller more flexibility.
  return elems
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return { cencode=cencode, cdecode=cdecode }
