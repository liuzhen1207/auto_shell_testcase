#!/bin/bash
# TDB-1442 僵尸会话探测驱动
#   usage: user_session_probe.sh <adminUser> <adminPw> <user> <userPw>
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
for _p in "$BASE/conf/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
NEW=${NEW:-v20131rc3_1117_ac7f95e}
HOST=${HOST:-172.16.2.2}
BUILD=/data2/iotdb/$NEW
CP="$BUILD/lib/timechodb-server-2.0.13.1.jar:$BUILD/lib/common-dependency.jar"
DIR=/tmp/usersession_$$
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

if ! javac -cp "$CP" -d "$DIR" "$BASE/tools/UserSessionProbe.java" > "$DIR/javac.log" 2>&1; then
  echo "COMPILE_FAILED"; head -3 "$DIR/javac.log"; exit 3
fi

java -cp "$CP:$DIR" UserSessionProbe "$HOST" 6667 "$1" "$2" "$3" "$4" 2>&1
