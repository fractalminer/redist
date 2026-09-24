#!/bin/bash
set -eo pipefail

# NOTE: when it is running as a systemd service you can also use:
# systemd-cgls --user-unit node-manager.service

pid="$(systemctl --user show -P MainPID node-manager)"
#parent_pid="$(ps -o ppid= -p "$pid")"

watch_pid="$pid"

watch -n.1 pstree -pa "$watch_pid"