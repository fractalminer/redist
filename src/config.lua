-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local freeze = require( 'moon.freeze' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local harden = assert( freeze.harden )
local format = assert( string.format )

-----------------------------------------------------------------
-- Helpers.
-----------------------------------------------------------------
local function HOME( rel_path )
  assert( rel_path )
  local home = assert( os.getenv( 'HOME' ),
                       'HOME variable not set' )
  return format( '%s/%s', home, rel_path )
end

local function REDIST( rel_path )
  local redist = 'dev/redist'
  return HOME( format( '%s/%s', redist, rel_path ) )
end

-----------------------------------------------------------------
-- Config.
-----------------------------------------------------------------
return harden{
  general={
    -- HOST='192.168.1.214', -- thelio/ethernet
    HOST='127.0.0.1',
    PORT=6379,
    CONNECT_TIMEOUT_SECS=10,
    COMPRESSION_METHOD='zstd',
    -- The ideal value of this compression level depends on up-
    -- load bandwidth to the redis server: lower bandwidths want
    -- higher compression levels, and vice versa, for optimal
    -- overall build times.
    COMPRESSION_LEVEL=1,
    USE_F_REWRITE_INCLUDES=false,
    -- This will enable using a local redis for data that never
    -- needs to be read by a remote worker, to reduce latency.
    -- Note that it is a different port so that it doesn't con-
    -- flict with a remote redis that is forwarded on
    -- 127.0.0.1:6379.
    ENABLE_LOCAL_REDIS=false,
    PORT_LOCAL=6380,
  },

  local_cache={
    LOCATION=REDIST( 'cache/cache.db' ),
    MAX_SIZE_BYTES=48 * 1024 * 1024 * 1024,
  },

  worker={
    QUEUE_POLL_TIMEOUT_SECS=5,
    ADVERTISE_INTERVAL_SECS=10,
    EXPIRE_ADVERTISE_SECS=15,
    POPEN_POLL_TIMEOUT_MILLIS=1000,
    POPEN_TIMEOUT_SECS=600,
    SEND_PREPROCESSED_DELTAS=true,
  },

  builder={
    EXPIRE_LOCAL_TASK=3600,
    EXPIRE_REMOTE_TASK=3600,
    REMOTE_FLAGS={
      ADD={
        CLANG={
          -- The Lua source code, which is full of macros, causes
          -- a lot of these when clang compiles the preprocessed
          -- source, but they are harmless.
          '-Wno-parentheses-equality', --
        },
        GCC={},
      },
      DEL={
        CLANG={
          -- clang warns about this one if we include it and it
          -- is compiling the already-preprocessed file.
          '-stdlib=libc++',
        },
        GCC={},
      },
    },
  },

  node_manager={
    MAX_WORKERS_PER_TYPE=48, --
    ADVERTISE_INTERVAL_SECS=10,
    EXPIRE_ADVERTISE_SECS=50, --
  },

  stats_collector={
    COLLECTION_INTERVAL_MILLIS=200, --
    EXPIRE_ADVERTISE_SECS=5, --
  },

  distributor={
    DEFAULT_STGY='smart',
    QUEUE_POLL_TIMEOUT_SECS=5,
    STGY_SMART_OVERFILL=0,
  },

  dashboard={
    -- 60 fps
    POLL_TIMEOUT_SECS=.01666,
    REDIS_UPDATE_INTERVAL_MILLIS=16.66,
    REDRAW_INTERVAL_MILLIS=16.66,
  },

  scripts={
    dec_if_positive='scripts/dec-if-positive.lua', --
  },
}
