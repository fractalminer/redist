-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local harden = assert( require( 'moon.freeze' ).harden )

return harden{
  general={
    HOST='bonobo', --
    PORT=6380, --
  },

  worker={
    POLL_TIMEOUT=10, --
    EXPIRE_ADVERTISE=60, --
  },
}
