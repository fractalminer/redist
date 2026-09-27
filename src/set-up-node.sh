#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

svc=node-manager

mkdir -p "../cache/"

user_services=~/.config/systemd/user
mkdir -p "$user_services"

# Make sure that it doesn't stop when we log out or have no more
# active ssh connections.
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger

service="$(realpath service/node-manager.service)"

echo "creating service symlink for $svc..."
ln -sf "$service" "$user_services/$svc.service"

echo "reloading user systemd..."
systemctl --user daemon-reload

# Make sure that it runs on startup even if we're not logged in.
echo "enabling service..."
systemctl --user enable node-manager

echo "restarting service $svc..."
systemctl --user start "$svc"