-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local harden = assert( require( 'moon.freeze' ).harden )

return harden{
  general={
    HOST='thelio', --
    PORT=6379, --
  },

  worker={
    POLL_TIMEOUT=10, --
    EXPIRE_ADVERTISE=60, --
  },

  builder={
    EXPIRE_LOCAL_TASK=3600, --
    EXPIRE_REMOTE_TASK=3600, --
  },
}
