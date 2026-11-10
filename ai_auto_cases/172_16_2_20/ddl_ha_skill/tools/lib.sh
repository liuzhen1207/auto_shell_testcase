#!/bin/bash
# lib.sh — 公共变量与查询函数（被 runner / 校验脚本 source）
set -u
CLI=${CLI:-/data2/iotdb/v20131rc1_1030_ab6d3de/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-TimechoDB@2021}
NEW=${NEW:-/data1/iotdb/v20131rc1_1030_ab6d3de}
DNS=${DNS:-"19 21 22 23 24"}
CNS=${CNS:-"16 17 18"}
SKILL=${SKILL:-/data2/iotdb/ddl_ha_skill}
ART=${ART:-/data2/iotdb/ddl_ha_results}

export NEW CLI PW DNS CNS

ip_of() { echo "172.16.2.$1"; }

# qdn <dn后缀> <sql> —— 在指定 DN 上执行（表模型）
qdn() {
  local n=$1 sql=$2
  bash "$CLI" -h "$(ip_of "$n")" -p 6667 -u root -pw "$PW" \
    -e "SET SQL_DIALECT=TABLE; $sql" 2>&1
}

# qdn_file <dn后缀> <sql文件> —— 整文件执行
qdn_file() {
  local n=$1 f=$2
  bash "$CLI" -h "$(ip_of "$n")" -p 6667 -u root -pw "$PW" -f "$f" 2>&1
}

# 从 CLI 输出里抽数据行（去掉边框、提示、列头）
rows_only() {
  grep -E '^\|' | grep -vE '^\|[[:space:]]*-+' | grep -viE '^\|[[:space:]]*(Time|_col|count|num_of|TableName|Table|dev)' | sed 's/^|//; s/|$//' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | grep -v '^$'
}

cluster_running_cnt() {
  bash "$CLI" -h "$(ip_of 19)" -p 6667 -u root -pw "$PW" -e "show cluster" 2>/dev/null | grep -c '|Running|'
}

# wait_cluster <期望台数> <超时秒>
wait_cluster() {
  local want=${1:-8} timeout=${2:-180} t=0
  while [ $t -lt "$timeout" ]; do
    [ "$(cluster_running_cnt)" -ge "$want" ] && return 0
    sleep 5; t=$((t+5))
  done
  return 1
}

# schema_replica_dns <db> —— 输出该库 SchemaRegion 所在 DN 列表
schema_replica_dns() {
  local db=$1
  bash "$CLI" -h "$(ip_of 19)" -p 6667 -u root -pw "$PW" -e "show regions" 2>/dev/null \
    | awk -F'|' -v db="$db" '$3 ~ /SchemaRegion/ && $4 ~ db {gsub(/ /,"",$7); print $7}'
}

# data_replica_dns <db> —— 输出该库 DataRegion 所在 DN 列表（去重）
data_replica_dns() {
  local db=$1
  bash "$CLI" -h "$(ip_of 19)" -p 6667 -u root -pw "$PW" -e "show regions" 2>/dev/null \
    | awk -F'|' -v db="$db" '$3 ~ /DataRegion/ && $4 ~ db {gsub(/ /,"",$7); print $7}' | sort -u
}
