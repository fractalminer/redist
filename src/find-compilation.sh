#!/bin/bash
set -eo pipefail
# set -x

xunit=$1
[[ -n "$xunit" ]]
xunit="${xunit//\//.}"
xunit="${xunit//\.cpp/}"
echo "searching for translation unit pattern: $xunit"

keys=$(./redis-cli.sh keys 'farm:compile:cpp:task:*:input')

find_it() {
  for key in $keys; do
    input="$(./redis-cli.sh hget $key description)"
    echo "key:$key|input:$input"
  done | grep "\/$xunit.cpp" | sort | head -n1
}

input_key=$(find_it | sed -rn 's/^key:(.*)\|.*/\1/p')
[[ -n "$input_key" ]]

# input_key=farm:compile:cpp:task:c6e9959a78c3ce0f83c1c98b55546973:input
echo "input  key: $input_key"

output_key="${input_key//:input/:output}"
echo "output key: $output_key"

worker_key="${input_key//:input/:worker}"
echo "output key: $worker_key"

get_output() {
  out="$(./redis-cli.sh hget "$output_key" "$1")"
  eval "$1=\$out"
}

get_worker() {
  out="$(./redis-cli.sh hget "$worker_key" "$1")"
  eval "$1=\$out"
}

get_output time_micros
get_output status
get_worker node

echo "time(us): $time_micros"
echo "node:     $node"
echo "status:   $status"