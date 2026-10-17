#!/bin/bash
# ---------------------------------------------------------------
# Control tool for sending commands to nodes.
# ---------------------------------------------------------------
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

# ---------------------------------------------------------------
# Includes.
# ---------------------------------------------------------------
source ~/dev/utilities/bashlib/util.sh

# ---------------------------------------------------------------
# Options.
# ---------------------------------------------------------------
nodes_all=(geekom1 geekom2 geekom3 darter2 meerkat bonobo thelio)

categories=(
  "systemctl"
  "redis-cmd"
  "power"
)

# ---------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------
# Only allows selecting a single result.
get_input_single() {
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

# Allows selecting multiple results.
get_input_multi() {
  local title="$1"
  shift
  selected=$(
    printf '%s\n' "$@" \
      | fzf \
          --height="~100%" \
          --disabled \
          --bind "j:down,k:up" \
          --prompt="$title: " \
          --no-info
  )
}

get_hostname_and_id() {
  local node="$1"
  [[ -n "$node" ]] || die 'empty node'
  [[ "$node" =~ ([^-]+)-(.*) ]]
  hostname="${BASH_REMATCH[1]}"
  id="${BASH_REMATCH[2]}"
  [[ -n "$hostname" ]] || die 'empty hostname'
  [[ -n "$id" ]] || die 'empty id'
  hostname="$hostname.local"
}

bar() {
  [[ -z "$COLUMNS" ]] && COLUMNS=65
  local n="$COLUMNS"
  for (( i=0; i < n; i++ )); do
    echo -n '-'
  done
}

print_title() {
  bar
  echo -e " ${c_yellow}${s_bold}$*$c_norm "
  bar
}

# ---------------------------------------------------------------
# Get Input.
# ---------------------------------------------------------------
get_nodes() {
  local options=(
    ALL
    "${nodes_all[@]}"
  )
  # Trick: printf has a built-in rule: if you provide more argu-
  # ments than it has placeholders (%s), it loops back to the be-
  # ginning of the format string and re-uses it for every remaining
  # argument. This has the effect of putting new lines between each
  # array element before they get fed into fzf.
  get_input_multi "CHOOSE NODE" "${options[@]}"
  [[ -z "$selected" ]] && exit 1
  if [[ "${selected,,}" == all ]]; then
    nodes=("${nodes_all[@]}")
  else
    # Read multiline string into an array named 'nodes'.
    mapfile -t nodes <<< "$selected"
  fi
  return 0
}

get_category() {
  get_input_single "CHOOSE CATEGORY" "${categories[@]}"
  [[ -z "$selected" ]] && exit 1
  category="$selected"
  return 0
}

get_action() {
  local category="$1"
  declare -a actions
  local title="CHOOSE ACTION"
  case "$category" in
    "systemctl")
      actions=(
        "logs"
        "start"
        "stop"
        "restart"
        "status"
      )
      get_input_single "$title" "${actions[@]}"
      [[ -z "$selected" ]] && exit 1
      action="$selected"
      ;;
    "redis-cmd")
      actions=(
        "update"
        "log-level"
      )
      get_input_single "$title" "${actions[@]}"
      [[ -z "$selected" ]] && exit 1
      action="$selected"
      case "$action" in
        update)
          ;;
        "log-level")
          levels=(OFF ERROR WARNING INFO DEBUG TRACE)
          get_input_single "CHOOSE LEVEL" "${levels[@]}"
          [[ -z "$selected" ]] && exit 1
          action="$action=$selected"
          ;;
        *)
          die "unrecognized action: $action"
          ;;
      esac
      ;;
    "power")
      actions=(
        "on"
        "off"
      )
      get_input_single "$title" "${actions[@]}"
      [[ -z "$selected" ]] && exit 1
      action="$selected"
      ;;
    *)
      die "unrecognized category: $category"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------
# Implementation.
# ---------------------------------------------------------------
node_manager_service_logs() {
  ssh "$hostname" "cd ~/dev/redist/src && ./node-manager-systemctl.sh logs"
}

node_manager_service_start() {
  ssh "$hostname" "cd ~/dev/redist/src && ./node-manager-systemctl.sh start"
}

node_manager_service_stop() {
  ssh "$hostname" "cd ~/dev/redist/src && ./node-manager-systemctl.sh stop"
}

node_manager_service_restart() {
  ssh "$hostname" "cd ~/dev/redist/src && ./node-manager-systemctl.sh restart"
}

node_manager_service_status() {
  ssh "$hostname" "cd ~/dev/redist/src && ./node-manager-systemctl.sh status"
}

node_manager_command_update() {
  [[ -n "$hostname" ]] || die 'hostname not set'
  [[ -n "$id" ]] || die 'id not set'
  local name="${hostname//.local}"
  ./redis-cli.sh set "farm:nodectl:$name-$id:update" 1
}

node_manager_command_level() {
  local level="$1"
  [[ -n "$level" ]] || die 'level not set'
  local name="${hostname//.local}"
  ./redis-cli.sh set "farm:nodectl:$name-$id:loglevel" "$level"
}

node_host_power_on() {
  [[ -n "$hostname" ]] || die 'hostname not set'
  ~/dev/utilities/farm/geekom-on.sh "$hostname"
}

node_host_power_off() {
  [[ -n "$hostname" ]] || die 'hostname not set'
  ~/dev/utilities/farm/geekom-off.sh "$hostname"
}

# ---------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------
execute() {
  local hostname="$1"
  local id="$2"
  local cmd="$3"
  local extra="$4"

  case "$cmd" in
    "systemctl>logs")
      node_manager_service_logs
      ;;
    "systemctl>start")
      node_manager_service_start
      ;;
    "systemctl>stop")
      node_manager_service_stop
      ;;
    "systemctl>restart")
      node_manager_service_restart
      ;;
    "systemctl>status")
      node_manager_service_status
      ;;
    "redis-cmd>update")
      node_manager_command_update
      ;;
    "redis-cmd>log-level")
      node_manager_command_level "$extra"
      ;;
    "power>on")
      node_host_power_on
      ;;
    "power>off")
      node_host_power_off
      ;;
  esac
}

# ---------------------------------------------------------------
# Main.
# ---------------------------------------------------------------
main() {
  clear

  interactive=1

  category="$1"; shift || true
  if [[ -z "$category" ]]; then get_category; fi

  action="$1"; shift || true
  if [[ -z "$action" ]]; then get_action "$category"; fi

  extra=
  if [[ "$action" =~ ([^=]+)=(.*) ]]; then
    action="${BASH_REMATCH[1]}"
    extra="${BASH_REMATCH[2]}"
  fi

  declare -a nodes
  if (( $# == 0 )); then
    get_nodes
  elif [[ "$#" == 1 && "${1,,}" == "all" ]]; then
    interactive=0
    nodes=("${nodes_all[@]}")
  else
    interactive=0
    nodes=("$@")
  fi

  echo "CATEGORY:"
  echo "- $category"
  echo "ACTION:"
  echo "- $action"
  if [[ -n "$extra" ]]; then
    echo "PARAM:"
    echo "- $extra"
  fi
  echo "NODES:"
  for node in "${nodes[@]}"; do
    get_hostname_and_id "$node"
    echo "- $node"
    echo "  - hostname: $hostname"
    echo "  - id:       $id"
  done

  echo
  if (( interactive == 1 )); then
    echo -n 'OK? [y/n] '
    read -a yesno
    [[ "$yesno" != "y" ]] && exit 1
  fi

  for node in "${nodes[@]}"; do
    print_title "$node"
    get_hostname_and_id "$node"
    execute                   \
      "$hostname"             \
      "$id"                   \
      "${category}>${action}" \
      "$extra"
  done

  return 0
}

# ---------------------------------------------------------------
# Launch.
# ---------------------------------------------------------------
main "$@"