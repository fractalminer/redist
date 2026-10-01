#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

echo 'NOTE: this should only be run on the permanent redis host.'
exit 1  # remove to run.

svc=redis-official

user_services=~/.config/systemd/user
mkdir -p "$user_services"

# Make sure that it doesn't stop when we log out or have no more
# active ssh connections.
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger

service="$(realpath "service/$svc.service")"

echo "creating service symlink for $svc..."
ln -sf "$service" "$user_services/$svc.service"

echo "reloading user systemd..."
systemctl --user daemon-reload

# Make sure that it runs on startup even if we're not logged in.
echo "enabling service..."
systemctl --user enable "$svc"

echo "starting service $svc..."
systemctl --user start "$svc"