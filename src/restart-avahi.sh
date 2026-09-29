#!/bin/bash
# Use this when switching between ethernet and wifi to
# get Avahi to redefine darter2.local.

sudo systemctl restart avahi-daemon
avahi-resolve -4 -n "$(hostname).local"