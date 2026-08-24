-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local harden = assert( require( 'moon.freeze' ).harden )

return harden{
  general={
    HOST='192.168.1.214', -- thelio/ethernet
    -- HOST='192.168.1.98', -- bonobo
    PORT=6379, --
  },

  worker={
    QUEUE_POLL_TIMEOUT_SECS=5,
    ADVERTISE_INTERVAL_SECS=10,
    EXPIRE_ADVERTISE_SECS=60,
    POPEN_POLL_TIMEOUT_MILLIS=100,
    POPEN_TIMEOUT_SECS=600,
  },

  builder={
    EXPIRE_LOCAL_TASK=3600, --
    EXPIRE_REMOTE_TASK=3600, --
  },
}
