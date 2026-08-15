#!/bin/bash
set -e

source cxn.sh

redis-cli "$@"
