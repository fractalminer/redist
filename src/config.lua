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
  },

  worker={
    QUEUE_POLL_TIMEOUT_SECS=1,
    ADVERTISE_INTERVAL_SECS=5,
    EXPIRE_ADVERTISE_SECS=20,
    POPEN_POLL_TIMEOUT_MILLIS=100,
    POPEN_TIMEOUT_SECS=600,
  },

  builder={
    EXPIRE_LOCAL_TASK=3600, --
    EXPIRE_REMOTE_TASK=3600, --
  },

  node_manager={
    MAX_WORKERS_PER_TYPE=10, --
    EXPIRE_ADVERTISE_SECS=5, --
  },

  scripts={
    dec_if_positive='scripts/dec-if-positive.lua', --
  },
}
