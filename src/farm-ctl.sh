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
# Commands.
# ---------------------------------------------------------------
commands=(
  "up-dash-down"
  "up"
  "dash"
  "down"
)

# ---------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------
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

function maybe_remote() {
  local host=$(redist_host)
  local cmd="fish -c '$1'"
  if [[ ! "$(hostname)" =~ thelio && "$host" == "127.0.0.1" ]]; then
    echo 'redirecting through linode...'
    ssh -t linode "ssh -t 127.0.0.1 -p 12345 '$cmd'"
  else
    fish -c "$cmd"
  fi
}

# ---------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------
function command_up() {
  print_title "Starting up build farm"
  ./node-manager-systemctl.sh start
  maybe_remote '
    cd ~/dev/redist/src;
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
  maybe_remote '
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
  maybe_remote 'cd /home/dsicilia/dev/redist/src; lua dashboard.lua'
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