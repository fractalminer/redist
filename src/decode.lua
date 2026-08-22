-- Compile Command Decoder.
-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local str = require( 'moon.str' )
local tbl = require( 'moon.tbl' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local deep_copy = assert( tbl.deep_copy )

local concat = table.concat
local insert = table.insert
local format = string.format
local remove = table.remove
local sort = table.sort

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
str.enable_string_injections()

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function errorf( ... ) error( format( ... ) ) end

local function is_option( what )
  assert( what )
  assert( #what > 0 )
  return what:sub( 1, 1 ) == '-'
end

local function cdecode( elems )
  local i = 1
  local decoded = {
    binary=nil, --
    special_flags={
      MD=nil, --
      MMD=nil, --
      MT=nil, --
      MF=nil, --
      E=nil, --
      c=nil, --
      o=nil, --
      x=nil, --
    },
    flags={}, -- remaining flags.
    includes={}, -- could be -I or -isystem.
    input_object_files={}, --
    input_c_cpp_file=nil, --
  }
  while elems[i] do
    local l, r = elems[i], elems[i + 1]
    local function key_val( where )
      if not r or is_option( r ) then
        errorf( 'missing argument to %s', l )
      end
      if decoded[where] then
        errorf( 'invalid command line: multiple %s', l )
      end
      decoded.special_flags[where] = r
      i = i + 1
    end
    local function add_c_cpp()
      if decoded.input_c_cpp_file then
        error( 'cannot have multiple c/cpp input files' )
      end
      decoded.input_c_cpp_file = l
    end
    if i == 1 then
      if is_option( l ) then
        error( 'missing binary in compile command' )
      end
      decoded.binary = l
    elseif l == '-MD' then
      decoded.special_flags.MD = true
    elseif l == '-MMD' then
      decoded.special_flags.MMD = true
    elseif l == '-c' then
      decoded.special_flags.c = true
    elseif l == '-E' then
      decoded.special_flags.E = true
    elseif l == '-MT' then
      key_val( 'MT' )
    elseif l == '-MF' then
      key_val( 'MF' )
    elseif l == '-o' then
      key_val( 'o' )
    elseif l == '-x' then
      key_val( 'x' )
    elseif l == '-I' then
      if not r or is_option( r ) then
        errorf( 'missing argument to %s', l )
      end
      insert( decoded.includes, l )
      insert( decoded.includes, r )
      i = i + 1
    elseif l == '-isystem' then
      if not r or is_option( r ) then
        errorf( 'missing argument to %s', l )
      end
      insert( decoded.includes, l )
      insert( decoded.includes, r )
      i = i + 1
    else
      if is_option( l ) then
        if l:sub( 1, 2 ) == '-I' then
          insert( decoded.includes, l )
        else
          insert( decoded.flags, l )
        end
      elseif l:sub( -2, -1 ) == '.o' then
        insert( decoded.input_object_files, l )
      elseif l:sub( -2, -1 ) == '.c' then
        add_c_cpp()
      elseif l:sub( -2, -1 ) == '.C' then
        add_c_cpp()
      elseif l:sub( -4, -1 ) == '.cpp' then
        add_c_cpp()
      elseif l:sub( -4, -1 ) == '.CPP' then
        add_c_cpp()
      elseif l:sub( -4, -1 ) == '.cxx' then
        add_c_cpp()
      elseif l:sub( -4, -1 ) == '.CXX' then
        add_c_cpp()
      else
        errorf( 'unrecognized argument form: %s', l )
      end
    end
    i = i + 1
  end
  return decoded
end

local function cvalidate( decoded )
  assert( decoded.binary, 'missing compiler binary' )
  local sf = assert( decoded.special_flags )
  local has_dep_flag = (sf.MD or sf.MMD or sf.MT or sf.MF)
  local has_objects = (#decoded.input_object_files > 0)
  local has_c_cpp = (decoded.input_c_cpp_file ~= nil)
  if has_dep_flag and has_objects then
    error( 'cannot have both deps flags and object file inputs' )
  end
  if sf.MD and sf.MMD then
    error( 'cannot have both -MD and -MMD' )
  end
  if sf.c and sf.E then error( 'cannot have both -c and -E' ) end
  if sf.c and has_objects then
    error( 'cannot have both -c and object files as input' )
  end
  if sf.E and has_objects then
    error( 'cannot have both -E and object files as input' )
  end
  if sf.c and not has_c_cpp then
    error( '-c requires having c/cpp inputs' )
  end
  if sf.E and not has_c_cpp then
    error( '-E requires having c/cpp inputs' )
  end
end

local function cencode( o )
  local elems = {}
  local function add( what ) insert( elems, what ) end
  if o.binary then add( o.binary ) end
  if o.special_flags.x then
    add( '-x' )
    add( o.special_flags.x )
  end
  if o.special_flags.MD then add( '-MD' ) end
  if o.special_flags.MMD then add( '-MMD' ) end
  if o.special_flags.E then add( '-E' ) end
  if o.special_flags.c then add( '-c' ) end
  if o.special_flags.MF then
    add( '-MF' )
    add( o.special_flags.MF )
  end
  if o.special_flags.MT then
    add( '-MT' )
    add( o.special_flags.MT )
  end
  for _, flag in ipairs( o.flags ) do add( flag ) end
  for _, inc in ipairs( o.includes ) do add( inc ) end
  if o.input_c_cpp_file then add( o.input_c_cpp_file ) end
  if #o.input_object_files > 0 then
    for _, ofile in ipairs( o.input_object_files ) do
      add( ofile )
    end
  end
  if o.special_flags.o then
    add( '-o' )
    add( o.special_flags.o )
  end
  -- Return as a list to give the caller more flexibility.
  return elems
end

local function cround_trip( command )
  local function normalize( lst )
    local copy = deep_copy( lst )
    local prg = copy[1]
    remove( copy, 1 )
    sort( copy )
    insert( copy, 1, prg )
    return copy
  end
  assert( type( command ) == 'table' ) -- list
  local decoded = cdecode( command )
  cvalidate( decoded )
  local encoded = cencode( decoded )
  local before = concat( normalize( command ), ' ' )
  local after = concat( normalize( encoded ), ' ' )
  assert( after == before,
          format( 'command failed round trip:\nA: %s\nB: %s',
                  before, after ) )
  return decoded
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  cencode=cencode,
  cround_trip=cround_trip,
  -- These are not really supposed to be called directly, at
  -- least not at the time of writing. Better to just call
  -- cround_trip which will decode and validate then test encoded
  -- round trip, then return the decoded version. If all that
  -- passes then you know the command has been properly parsed
  -- with much more confidence than with just cdecode alone.
  cvalidate=error,
  cdecode=error,
}
