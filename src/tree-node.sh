#!/bin/bash
set -eo pipefail

pid="$(pgrep run-node-manager.sh -f)"
parent_pid="$(ps -o ppid= -p "$pid")"

watch_pid="$parent_pid"

watch -n.1 pstree -pa "$watch_pid"