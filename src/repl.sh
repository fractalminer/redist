#!/bin/bash
set -e

redis-cli -h bonobo -p 6380 ping
redis-cli -h bonobo -p 6380