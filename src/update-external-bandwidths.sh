#!/bin/bash
set -eo pipefail

bar() { printf "%${COLUMNS}s" | tr ' ' '-'; }

title() { bar; echo "$@"; bar; }

indent() { sed -r 's|(.*)|  \1|'; }

rm -f /tmp/redis-up-bandwidth.6379.json
rm -f /tmp/redis-dn-bandwidth.6379.json
rm -f /tmp/redis-up-bandwidth.6380.json
rm -f /tmp/redis-dn-bandwidth.6380.json

ports=( 6379 6381 )

title 'Individual Bandwidths:'
for port in ${ports[@]}; do
  { PORT="$port" ./bandwidth.sh | indent; } &
done

wait || exit 1

total_up=0
total_dn=0

echo
title 'Totals'
for port in ${ports[@]}; do
  up="$(cat "/tmp/redis-up-bandwidth.$port.json" | jq '.bandwidth_mbps')"
  dn="$(cat "/tmp/redis-dn-bandwidth.$port.json" | jq '.bandwidth_mbps')"
  total_up="$(lua -e "print( $total_up + $up )")"
  total_dn="$(lua -e "print( $total_dn + $dn )")"
done

echo "total_up: $total_up Mbps" | indent
echo "total_dn: $total_dn Mbps" | indent

sed -i -r "s/EXTERNAL_UPLOAD_BANDWIDTH=([.0-9]+)/EXTERNAL_UPLOAD_BANDWIDTH=$total_up/" ./config.lua
sed -i -r "s/EXTERNAL_DOWNLOAD_BANDWIDTH=([.0-9]+)/EXTERNAL_DOWNLOAD_BANDWIDTH=$total_dn/" ./config.lua

echo
title 'Edited:'
{
  cat ./config.lua | ag EXTERNAL_UPLOAD_BANDWIDTH   | sed -r 's/^ +//'
  cat ./config.lua | ag EXTERNAL_DOWNLOAD_BANDWIDTH | sed -r 's/^ +//'
} | column -t | indent