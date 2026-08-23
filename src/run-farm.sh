#!/bin/bash
set -e

[[ -n "$1" ]]

~/dev/utilities/consoles/open.sh farm-$1

tmux setw synchronize-panes on
tmux rename-window "FARM"