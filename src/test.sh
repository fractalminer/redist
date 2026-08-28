#!/bin/bash

echo 'HELLO'

child() {
  while true; do
    echo "$0 child: running: pid=$$ [$1]"
    sleep 1
  done
}

child &

while true; do
  echo "$0: running: pid=$$ [$1]"
  sleep 1
  # exit 0
done