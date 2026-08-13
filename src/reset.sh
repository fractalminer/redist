#!/bin/bash
set -e

source cxn.sh

echo -n 'CONFIRM: delete all redis keys? [y/n]: '
read -a answer

if [[ ! "$answer" =~ ^[yY].* ]]; then
  echo cancelled.
  exit 1
fi

echo DELETING...
redis-cli FLUSHALL
