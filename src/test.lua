-- local decode = require( 'decode' )
do
  local _<close>, fn = require( 'worker' )()

  local logger = require( 'moon.logger' )
  -- local json = require( 'moon.json' )

  logger.level = logger.levels.DEBUG

  -- local cmd = {
  --   'clang++', --
  --   '-c', 'file.cpp', --
  --   '-fcoverage-mapping', --
  --   '-Xclang', 'aaa', --
  --   '-Xclang', '-fbbb', --
  --   '-Xclang', '-fcoverage-prefix-mapx', --
  --   '-Xclang', '-fcoverage-prefix-map=ccc=bbb', --
  --   '-o', 'file.cpp.o', --
  -- }
  --
  -- json.print( decode.cround_trip( cmd ) )

  local input =
      '/home/dsicilia/dev/revolution-now/src/terrain-mgr.cpp'
  local body = 'test'
  local ext = '.ii'

  print( fn( input, body, ext ) )
end