#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

svc=node-manager

user_services=~/.config/systemd/user
mkdir -p "$user_services"

service="$(realpath service/node-manager.service)"

echo "creating service symlink for $svc..."
ln -sf "$service" "$user_services/$svc.service"

echo "reloading user systemd..."
systemctl --user daemon-reload

echo "restarting service $svc..."
systemctl --user restart "$svc"
# systemctl --user start   "$svc"