-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local harden = assert( require( 'moon.freeze' ).harden )

return harden{
  general={
    HOST='192.168.1.214', -- thelio/ethernet
    -- HOST='192.168.1.98', -- bonobo
    -- HOST='127.0.0.1', -- loopback
    PORT=6379, --
    CONNECT_TIMEOUT_SECS=10,
    COMPRESSION_METHOD='zstd',
    -- The ideal value of this compression level depends on up-
    -- load bandwidth to the redis server: lower bandwidths want
    -- higher compression levels, and vice versa, for optimal
    -- overall build times.
    COMPRESSION_LEVEL=1,
  },

  worker={
    QUEUE_POLL_TIMEOUT_SECS=5,
    ADVERTISE_INTERVAL_SECS=10,
    EXPIRE_ADVERTISE_SECS=50,
    POPEN_POLL_TIMEOUT_MILLIS=1000,
    POPEN_TIMEOUT_SECS=600,
  },

  builder={
    EXPIRE_LOCAL_TASK=3600, --
    EXPIRE_REMOTE_TASK=3600, --
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
    POLL_TIMEOUT_SECS=.1,
    REDIS_UPDATE_INTERVAL_MILLIS=200,
    REDRAW_INTERVAL_MILLIS=200,
  },

  scripts={
    dec_if_positive='scripts/dec-if-positive.lua', --
  },
}
