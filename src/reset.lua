-----------------------------------------------------------------
-- Imports.
-----------------------------------------------------------------
local farm = require( 'farm' )
local ru = require( 'redis-util' )

local logger = require( 'moon.logger' )
local str = require( 'moon.str' )

local argparse = require( 'argparse' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local fatal = assert( logger.fatal )

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
-- Parsed CLI args will be put here.
local args

str.enable_string_injections()

-----------------------------------------------------------------
-- Implementation.
-----------------------------------------------------------------
local function reset( cxn, mode )
  if mode == 'task_input_output' then
    assert( farm.reset_task_input_and_output( cxn ) )
  else
    fatal( 'unsupported mode: %s', mode )
  end
end

-----------------------------------------------------------------
-- Main.
-----------------------------------------------------------------
local function main()
  local parser = argparse( arg[0],
                           'ReDist Distributed Build Resetter' )

  -- LuaFormatter off
  parser:option( '--verbosity' )
        :choices{ 'error', 'warning', 'info', 'debug', 'trace' }
        :default( 'info' )
        :description( 'log level' )

  parser:option( '-m --mode' )
        :choices{ 'task_input_output', 'task_input', 'full' }
        :default( 'task_input_output' )
        :description( 'how much to clear' )
  -- LuaFormatter on

  args = parser:parse()

  local level = assert( logger.levels[args.verbosity:upper()] )
  logger.level = level

  local cxn<close> = assert( ru.connect() )

  reset( cxn, args.mode )
end

-----------------------------------------------------------------
-- Startup.
-----------------------------------------------------------------
os.exit( main() )
