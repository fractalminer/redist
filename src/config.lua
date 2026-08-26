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
    QUEUE_POLL_TIMEOUT_SECS=5,
    ADVERTISE_INTERVAL_SECS=5,
    EXPIRE_ADVERTISE_SECS=20,
    POPEN_POLL_TIMEOUT_MILLIS=100,
    POPEN_TIMEOUT_SECS=600,
    -- This should last at least as long as a task takes to run
    -- so that the counts don't disappear during that time.
    EXPIRE_APPROX_COUNT_SECS=600,
  },

  builder={
    EXPIRE_LOCAL_TASK=3600, --
    EXPIRE_REMOTE_TASK=3600, --
  },
}
