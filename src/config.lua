-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local harden = assert( require( 'moon.freeze' ).harden )

return harden{
  general={
    -- HOST='192.168.1.214', -- thelio/ethernet
    HOST='192.168.1.98', -- bonobo
    PORT=6379, --
  },

  worker={
    POLL_TIMEOUT=1, --
    EXPIRE_ADVERTISE=60, --
  },

  builder={
    EXPIRE_LOCAL_TASK=3600, --
    EXPIRE_REMOTE_TASK=3600, --
  },
}
