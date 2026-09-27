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
  redis={
    -- This must be either a hostname or "tunnel". The reason we
    -- need this is because unfortunately it is tricky to reli-
    -- ably distinguish a situation where 127.0.0.1 refers to a
    -- redis that is running locally vs one that is tunneled in.
    HOST='thelio',
    PORT=6379,
    CONNECT_TIMEOUT_SECS=10,
    -- This will enable using a local redis for data that never
    -- needs to be read by a remote worker, to reduce latency.
    -- Note that it is a different port so that it doesn't con-
    -- flict with a remote redis that is forwarded on
    -- 127.0.0.1:6379.
    ENABLE_LOCAL_REDIS=false,
    PORT_LOCAL=6380,
    -- When we are waiting for the redis DB to be available, how
    -- long should we wait before retrying. This should not be
    -- too short because it is expected that the node manager on
    -- e.g. darter2 will often be in a state where it cannot con-
    -- nect to redis, so we don't want it to be doing too much
    -- spinning in that case.
    INITIAL_CONNECT_WAIT_SECS=10,
  },

  general={
    COMPRESSION_METHOD='zstd',
    -- The ideal value of this compression level depends on up-
    -- load bandwidth to the redis server: lower bandwidths want
    -- higher compression levels, and vice versa, for optimal
    -- overall build times.
    COMPRESSION_LEVEL=1,
    USE_F_REWRITE_INCLUDES=false,
    -- Every n secs we'll check redis for a command to update the
    -- log level.
    UPDATE_LOG_LEVEL_INTERVAL_SECS=60,
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
    EVICT_CACHE_INTERVAL_SECS=43200, -- 12 hours
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
