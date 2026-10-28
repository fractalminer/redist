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
    NODE_RANK={
      'thelio', 'geekom1', 'geekom2', 'geekom3', 'meerkat',
      'bonobo', 'darter2',
    },
    -- The top N are considered "fast" nodes.
    FAST_NODES=4,
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
    multiroute={
      ENABLED=false,
      ROUTES={
        [6379]=4, --
        [6381]=2, --
      },
    },
    -- These estimate the total upload and download bandwidth in
    -- Mbps that we get to the redis server when we are tunneling
    -- from an external network. This is not relevant on the home
    -- network where our bandwidths are effectively infinite, but
    -- could be arbitrarily low when on an external network (and
    -- 40 Mbps is the upper limit for upload bandwidth of a cable
    -- internet connection, though we might get less than that
    -- when on a shared wifi network). These will be the sums
    -- across all routes to the redis server.
    EXTERNAL_UPLOAD_BANDWIDTH=58.78, -- Mbps
    EXTERNAL_DOWNLOAD_BANDWIDTH=150.31, -- Mbps
  },

  general={
    USE_F_REWRITE_INCLUDES=false,
    -- Every n secs we'll check redis for a command to update the
    -- log level.
    UPDATE_LOG_LEVEL_INTERVAL_SECS=30,
  },

  compression={
    -- In general, the ideal values of the compression levels de-
    -- pend on bandwidth: lower bandwidths want higher compres-
    -- sion levels, and vice versa, for optimal overall build
    -- times.
    --
    -- On the home network where we have practically infinite up-
    -- load bandwidth, we just use a level of one because it's a
    -- huge win and basically free.
    --
    -- But when we are on an external network the bottlenecks
    -- will be the external connection (i.e. upload from build
    -- host to redis and download from redis to build host) since
    -- we assume that connections between redis and other build
    -- nodes will be fast since they are all on the same network.
    --
    -- So for external connections we need to increase the com-
    -- pression levels to get optimal build times. zstd can go up
    -- to 19, but that is very slow and typically not optimal, so
    -- below yields optimal measured values for each bucket of
    -- bandwidths.
    P_LEVEL_FOR_FAST_UPLOAD=1,
    O_LEVEL_FOR_FAST_DOWNLOAD=1,
    -- Preprocessed file compression levels for external connec-
    -- tions.
    P_LEVELS_FOR_SLOW_UPLOAD_BANDWIDTH={
      -- We don't expect to go much higher than 40 Mbps on an ex-
      -- ternal connection. But if some day we do then we need to
      -- measure the optimal level there and add a tier. Note
      -- that these need to go in decreasing order of bandwidth.
      { min_bandwidth=40, level=8 },
      { min_bandwidth=30, level=9 }, -- TODO: measure.
      { min_bandwidth=20, level=11 }, -- TODO: measure.
      { min_bandwidth=10, level=13 }, -- TODO: measure.
      { min_bandwidth=5, level=15 }, -- TODO: measure.
    },
    -- Object file compression levels for external connections.
    O_LEVELS_FOR_SLOW_DOWNLOAD_BANDWIDTH={
      -- Here is it possible to get arbitrarily high numbers
      -- since there aren't the same limits on download bandwidth
      -- for cable internet connections.
      { min_bandwidth=40, level=1 }, -- TODO: measure.
      { min_bandwidth=30, level=3 }, -- TODO: measure.
      { min_bandwidth=20, level=5 }, -- TODO: measure.
      { min_bandwidth=10, level=7 }, -- TODO: measure.
      { min_bandwidth=5, level=9 }, -- TODO: measure.
    },
  },

  expire={
    WORKER_ADVERTISE_SECS=15,
    NODE_MANAGER_ADVERTISE_SECS=5, --
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
    ADVERTISE_INTERVAL_SECS=1,
    EVICT_CACHE_INTERVAL_SECS=43200, -- 12 hours
    ENABLE_LOCAL_AUTO_SCALE=true,
    -- The interval on which to check that we need to up-scale
    -- the local worker pool. This should be short so that we can
    -- react quickly when a compilation is initiated.
    CHECK_LOCAL_AUTO_SCALE_INTERVAL_SECS=1,
    -- Time interval on which we check for downscaling the local
    -- worker pool. NOTE: this is not the inactivity timeout it-
    -- self, it's just the interval on which we check whether we
    -- need to downscale; the timeout is the next parameter.
    CHECK_LOCAL_AUTO_UNSCALE_INTERVAL_SECS=120,
    -- If the local workers remain inactive for this amount of
    -- time then their pool will be drained until they are needed
    -- again. This should be long because once activity is de-
    -- tected that means that compile work is being done and so
    -- it is likely there will be more compilations soon.
    LOCAL_WORKER_INACTIVITY_TIMEOUT_SECS=3600,
  },

  node_telemetry={
    COLLECTION_INTERVAL_MILLIS=200, --
    EXPIRE_ADVERTISE_SECS=5, --
  },

  distributor={
    DEFAULT_STGY='smart',
    QUEUE_POLL_TIMEOUT_SECS=5,
    TOP_COMPILE_TIME_COUNT=15,
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
