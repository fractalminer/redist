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
    preprocess=false,
    input=nil,
    output=nil,
  }
  while true do
    if not elems[i] then break end
    local l, r = elems[i], elems[i + 1]
    local function key_val( where )
      assert( r,
              'invalid command line: missing argument to ' .. l )
      assert( not decoded[where],
              'invalid command line: multiple ' .. l )
      decoded[where] = r
      i = i + 2
    end
    if i == 1 then
      assert( not l:match( '^-' ),
              'missing compiler in compile command' )
      decoded.compiler = l
      i = i + 1
    elseif l == '-E' then
      decoded.preprocess = true
      i = i + 1
    elseif l == '-c' then
      key_val( 'input' )
    elseif l == '-o' then
      key_val( 'output' )
    else
      insert( decoded.flags, l )
      i = i + 1
    end
  end
  return decoded
end

local function cencode( o )
  local elems = {}
  local function add( what ) insert( elems, what ) end
  if o.compiler then add( o.compiler ) end
  for _, flag in ipairs( o.flags ) do add( flag ) end
  if o.preprocess then add( '-E' ) end
  if o.input then
    add( '-c' )
    add( o.input )
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
