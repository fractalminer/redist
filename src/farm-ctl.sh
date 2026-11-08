#!/bin/bash
set -eo pipefail


this_dir="$(dirname "$0")"
cd "$this_dir"

# ---------------------------------------------------------------
# Includes.
# ---------------------------------------------------------------
source ~/dev/utilities/bashlib/util.sh

source cxn.sh

# ---------------------------------------------------------------
# Constants.
# ---------------------------------------------------------------
commands=(
  "up-dash-down"
  "up"
  "dash"
  "down"
)

# ---------------------------------------------------------------
# Globals.
# ---------------------------------------------------------------
g_is_local=0

# ---------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------
function on_local_network() {
  if ping -W.5 -q -c1 thelio &>/dev/null; then
    return 0
  fi
  return 1
}

# Only allows selecting a single result.
function get_input_single() {
  local title="$1"
  shift
  selected=$(
    printf '%s\n' "$@" \
      | fzf \
          --height="~100%" \
          --disabled \
          --bind "j:down,k:up" \
          --prompt="$title: " \
          --no-info \
          --no-multi
  )
}

function get_command() {
  get_input_single "Choose command" "${commands[@]}"
  [[ -z "$selected" ]] && exit 1
  command="$selected"
  return 0
}

bar() {
  [[ -z "$COLUMNS" ]] && COLUMNS=65
  local n="$COLUMNS"
  for (( i=0; i < n; i++ )); do
    echo -n '-'
  done
  echo
}

print_title() {
  bar
  echo -e "> ${c_yellow}${s_bold}$*$c_norm "
  bar
}

function on_thelio() {
  local host=$(redist_host)
  local cmd="fish -c '$1'"
  # If we're already on thelio then just run local.
  if [[ "$(hostname)" =~ thelio ]]; then
    echo 'running local...'
    fish -c "$cmd"
    return
  fi
  # We're not on thelio so we need to go to thelio. If we're
  # on the local network then just go there.
  if (( g_is_local )); then
    echo 'redirecting through thelio...'
    ssh -t thelio.local "$cmd"
    return
  fi
  # We're not on the local network thus we need to route through
  # linode.
  echo 'redirecting through linode...'
  local x="'"
  cmd="${cmd//\'/\\\'}"
  ssh -t linode "ssh -t 127.0.0.1 -p 12345 '$cmd'"
}

function on_home_network() {
  local host=$(redist_host)
  local cmd="fish -c '$1'"
  if (( g_is_local )); then
    echo 'running local...'
    fish -c "$cmd"
    return
  fi
  # We're not on the local network thus we need to route through
  # thelio.
  on_thelio "$1"
}

# ---------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------
function command_up() {
  print_title "Starting up build farm"
  ./node-manager-systemctl.sh start
  on_home_network '
    cd ~/dev/redist/src
    ~/dev/utilities/farm/geekom-on.sh
    ./node-ctl.sh systemctl start geekom1
    ./node-ctl.sh systemctl start geekom2
    ./node-ctl.sh systemctl start geekom3
    ./node-ctl.sh systemctl start meerkat
    ./node-ctl.sh systemctl start bonobo
    ./node-ctl.sh systemctl start thelio
  '
}

function command_down() {
  print_title "Shutting down build farm"
  ./node-manager-systemctl.sh stop
  on_home_network '
    cd ~/dev/redist/src
    ./node-ctl.sh systemctl stop geekom1
    ./node-ctl.sh systemctl stop geekom2
    ./node-ctl.sh systemctl stop geekom3
    ./node-ctl.sh systemctl stop meerkat
    ./node-ctl.sh systemctl stop bonobo
    ./node-ctl.sh systemctl stop thelio
    ~/dev/utilities/farm/geekom-off.sh
  '
}

function command_dash() {
  print_title "Starting dashboard"
  on_thelio 'cd /home/dsicilia/dev/redist/src; lua dashboard.lua'
}

function command_up_dash_down() {
  command_up
  command_dash
  command_down
}

# ---------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------
function execute() {
  local cmd="$1"

  case "$cmd" in
    "up-dash-down")
      command_up_dash_down
      ;;
    "up")
      command_up
      ;;
    "down")
      command_down
      ;;
    "dash")
      command_dash
      ;;
    *)
      die "unrecognized command: $cmd"
      ;;
  esac
}

# ---------------------------------------------------------------
# Main.
# ---------------------------------------------------------------
function main() {
  clear

  on_local_network && g_is_local=1

  interactive=1

  command="$1"; shift || true
  if [[ -z "$command" ]]; then get_command; fi

  execute "$command"

  return 0
}

# ---------------------------------------------------------------
# Launch.
# ---------------------------------------------------------------
main "$@"