#!/bin/bash
set -e

source cxn.sh

host="$(redist_host)"

ping -i 0.1 -c 100 "$host"
