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
  nodes={
    -- The nodes will be given preference in this order when a
    -- compile task gets distributed and there are multiple nodes
    -- available that could process it. Basically we want the
    -- faster nodes at the top.
    node_rank={
      'thelio-a684a28cee8cfbd37c895a6266564755',
      'geekom1-c2e35a1b5afe33bd6aa9c1d26a977589',
      'geekom2-55de77073bc7647725ce62096a978bf1',
      'geekom3-e322c033f3841b7c9dbd9c9a6a9870c1',
      'meerkat-794558ad67d03a155ed635a464b2b5e4',
      'bonobo-a3a2da568ef6838c1ed2ed9463e5507b',
      'darter2-b0db31b5853309832ffb1a156766e000',
    },
    -- The top N are considered "fast" nodes.
    fast_nodes=4,
  },

  redis={
    host={
      -- This must be either a hostname or "tunnel". The reason
      -- we need that is because unfortunately it is tricky to
      -- reliably distinguish a situation where 127.0.0.1 refers
      -- to a redis that is running locally vs one that is tun-
      -- neled in.
      --
      -- We need both the name and the IP because when we connect
      -- we want to use the IP directly because somehow it is a
      -- lot faster, while we want the hostname so that we can
      -- easily detect if we are running on the same host as the
      -- redis server so that the node manager knows to run the
      -- distributor.
      NAME='thelio',
      IP='192.168.1.214',
    },
    PORT=6379,
    -- Making this non-zero enables a TCP-reachability check be-
    -- fore each connection is initiated so that we can put a
    -- timeout on the connection (to prevent hanging when redis
    -- is not reachable) without putting a timeout on the socket
    -- (which would have other consequences). It is off by de-
    -- fault because it requires an additional ping to the server
    -- on each connection, which can be taxing for builders.
    CONNECT_TIMEOUT_SECS=0,
    -- This will enable using a local redis for data that never
    -- needs to be read by a remote worker, to reduce latency.
    -- Note that it is a different port so that it doesn't con-
    -- flict with a remote redis that is forwarded on
    -- 127.0.0.1:6379. This should always be true because the
    -- node manager will run a local redis on 6380 on each node.
    ENABLE_LOCAL=true,
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
    COMPRESSION_LEVEL=9,
    USE_F_REWRITE_INCLUDES=false,
    -- Every n secs we'll check redis for a command to update the
    -- log level.
    UPDATE_LOG_LEVEL_INTERVAL_SECS=30,
  },

  expire={
    WORKER_ADVERTISE_SECS=15,
    NODE_MANAGER_ADVERTISE_SECS=50, --
    -- For things associated with task processing, e.g. task in-
    -- put, task queues, etc. But not task output; those are
    -- cached.
    TASKS=3600,
  },

  local_cache={
    LOCATION=REDIST( 'cache/cache.db' ),
    MAX_SIZE_BYTES=48 * 1024 * 1024 * 1024,
  },

  worker={
    QUEUE_POLL_TIMEOUT_SECS=5,
    ADVERTISE_INTERVAL_SECS=10,
    POPEN_POLL_TIMEOUT_MILLIS=1000,
    POPEN_TIMEOUT_SECS=600,
    SEND_PREPROCESSED_DELTAS=true,
  },

  builder={
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
    EVICT_CACHE_INTERVAL_SECS=43200, -- 12 hours
  },

  node_telemetry={
    COLLECTION_INTERVAL_MILLIS=200, --
    EXPIRE_ADVERTISE_SECS=5, --
  },

  distributor={
    DEFAULT_STGY='smart',
    QUEUE_POLL_TIMEOUT_SECS=5,
    STGY_SMART_OVERFILL=0,
  },

  dashboard={
    -- Sleep time in each main loop iteration. If there are no
    -- active workers for INACTIVITY_TIMEOUT_SECS then it will
    -- fall to the inactive timeout, otherwise the active one.
    ACTIVE_POLL_TIMEOUT_SECS=.01666, -- 60 fps
    INACTIVE_POLL_TIMEOUT_SECS=2.0,
    INACTIVITY_TIMEOUT_SECS=60,
    REDIS_UPDATE_INTERVAL_MILLIS=16.66,
    REDRAW_INTERVAL_MILLIS=16.66,
  },

  scripts={
    dec_if_positive='scripts/dec-if-positive.lua', --
  },
}
