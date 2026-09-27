# This is a source-able wrapper that allows running a command in
# a way that will wait for it to complete when a stop signal is
# received.
on_stop_signal() { echo -e "PID $$ RECV stop signal"; }

waiter() {
  trap on_stop_signal  2  # SIGINT
  trap on_stop_signal 15  # SIGTERM

  "$@" &
  local pid=$!

  { wait "$pid"; res="$?"; } || true
  if [[ "$res" == 143 ]]; then
    # This is 128+15 where 15 is SIGTERM. This means that the
    # process successfully terminated due to SIGTERM, which will
    # happen e.g. when systemd restarts it. So we will just con-
    # sider this a successful exit.
    res=0
  fi
  kill "$pid" || true
  wait "$pid" || true
  return "$res"
}
