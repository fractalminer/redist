#!/bin/bash
set -e

source cxn.sh

r() { redis-cli "$@"; }

# strings/numbers.
r SET age 14
r SET eight:nine:baz 777
r SET n 24
r SET name:first david
r SET name:last sicilia
r SET one:two:three 555

# lists.
r RPUSH lst 42
r RPUSH lst 99
r RPUSH lst hello

r RPUSH hosts bonobo
r RPUSH hosts darter
r RPUSH hosts meerkat
r RPUSH hosts thelio

# hashes.
r HSET aaa:bbb:ccc:ddd n 42

r HSET residents:david alias fractalminer
r HSET residents:david city nyc
r HSET residents:david zipcode 10019
r HSET residents:david age 45
