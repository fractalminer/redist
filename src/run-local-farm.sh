#!/bin/bash
set -e

[[ -n "$1" ]]

tmux setw synchronize-panes yes
tmux rename-window "FARM-$(hostname)-local"

~/dev/utilities/consoles/open.sh farm-$1-local