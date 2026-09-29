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
nodes_all=(
  geekom1-c2e35a1b5afe33bd6aa9c1d26a977589
  geekom2-55de77073bc7647725ce62096a978bf1
  geekom3-e322c033f3841b7c9dbd9c9a6a9870c1
  darter2-b0db31b5853309832ffb1a156766e000
  meerkat-794558ad67d03a155ed635a464b2b5e4
  bonobo-a3a2da568ef6838c1ed2ed9463e5507b
  thelio-a684a28cee8cfbd37c895a6266564755
)

categories=(
  "Node Manager SYSTEMCTL"
  "Node Manager REDIS CMD"
  "Node Host"
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
  if [[ "$selected" == ALL ]]; then
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
    "Node Manager SYSTEMCTL")
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
    "Node Manager REDIS CMD")
      actions=(
        "update"
        "level"
      )
      get_input_single "$title" "${actions[@]}"
      [[ -z "$selected" ]] && exit 1
      action="$selected"
      case "$action" in
        update)
          ;;
        level)
          levels=(OFF ERROR WARNING INFO DEBUG TRACE)
          get_input_single "CHOOSE LEVEL" "${levels[@]}"
          [[ -z "$selected" ]] && exit 1
          extra="$selected"
          ;;
        *)
          die "unrecognized action: $action"
          ;;
      esac
      ;;
    "Node Host")
      actions=(
        "Power ON"
        "Power OFF"
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
  ./redis-cli.sh set "farm:nodectl:$hostname-$id:update" 1
}

node_manager_command_level() {
  local level="$1"
  [[ -n "$level" ]] || die 'level not set'
  ./redis-cli.sh set "farm:nodectl:$hostname-$id:loglevel" "$level"
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
    "Node Manager SYSTEMCTL>logs")
      node_manager_service_logs
      ;;
    "Node Manager SYSTEMCTL>start")
      node_manager_service_start
      ;;
    "Node Manager SYSTEMCTL>stop")
      node_manager_service_stop
      ;;
    "Node Manager SYSTEMCTL>restart")
      node_manager_service_restart
      ;;
    "Node Manager SYSTEMCTL>status")
      node_manager_service_status
      ;;
    "Node Manager REDIS CMD>update")
      node_manager_command_update
      ;;
    "Node Manager REDIS CMD>level")
      node_manager_command_level "$extra"
      ;;
    "Node Host>Power ON")
      node_host_power_on
      ;;
    "Node Host>Power OFF")
      node_host_power_off
      ;;
  esac
}

# ---------------------------------------------------------------
# Main.
# ---------------------------------------------------------------
main() {
  clear
  get_category
  get_action "$category"
  get_nodes

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
  echo -n 'OK? [y/n] '
  read -a yesno
  [[ "$yesno" != "y" ]] && exit 1

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
main