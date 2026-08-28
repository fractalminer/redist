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
  kill "$pid" || true
  wait "$pid" || true
  return "$res"
}
