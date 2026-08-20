-----------------------------------------------------------------
-- ReDist Config.
-----------------------------------------------------------------
local harden = assert( require( 'moon.freeze' ).harden )

return harden{
  general={
    HOST='127.0.0.1', --
    PORT=6379, --
  },

  worker={
    POLL_TIMEOUT=10, --
    EXPIRE_ADVERTISE=60, --
  },

  builder={
    -- TODO
  },
}
