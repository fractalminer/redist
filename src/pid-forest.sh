#!/bin/bash
set -eo pipefail

ps -eo pid,ppid,pgid,sid,stat,wchan:30,cmd --forest
