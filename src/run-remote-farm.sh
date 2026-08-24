#!/bin/bash
set -e

[[ -n "$1" ]]

tmux setw synchronize-panes yes
tmux rename-window "FARM-$(hostname)-remote"

~/dev/utilities/consoles/open.sh farm-$1-remote