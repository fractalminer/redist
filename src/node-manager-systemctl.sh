#!/bin/bash
set -eo pipefail

SERVICE=node-manager

cmd="$1"

usage() {
  echo "usage: $0 <cmd>"
  exit 1
}

[[ -n "$cmd" ]] || usage

if [[ "$cmd" == logs ]]; then
  exec journalctl -f --user -u "$SERVICE" -n1000 --output=cat
fi

systemctl --user "$cmd" "$SERVICE"