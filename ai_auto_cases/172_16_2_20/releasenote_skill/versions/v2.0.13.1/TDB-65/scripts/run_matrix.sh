#!/bin/bash
# run_matrix.sh — TDB-65 接口 × 方言 × 状态矩阵取证
# 用法: bash run_matrix.sh <CLIENT_HOME> <HOST> <OUT_DIR>
# 依赖: 发行包 lib/* 中的 session/jdbc 类；本期 java/SessionShow.java、JdbcShow.java 已编译到 $OUT_DIR/classes
set -u
CLIENT=${1:-/data2/iotdb/v20131rc1_1030_ab6d3de/timechodb-2.0.13.1-bin}
HOST=${2:-172.16.2.19}
OUT=${3:-/data2/iotdb/rc10_matrix/rn_verify/TDB-65/evidence}
JAR="$CLIENT/lib/*"
CLI="$CLIENT/sbin/start-cli.sh"
PW='TimechoDB@2021'
CLS=$(dirname "$0")/../classes
mkdir -p "$OUT"

cols_cli(){ grep -m1 '^|' "$1" | awk -F'|' '{print NF-2}'; }

run_java(){ # iface dialect sql out
  local f=$4
  if [ "$1" = session ]; then
    java -cp "$JAR:$CLS" SessionShow "$HOST" 6667 "$2" "$3" > "$f" 2>&1
  else
    java -cp "$JAR:$CLS" JdbcShow "$HOST" 6667 "$2" "$3" > "$f" 2>&1
  fi
}

run_cli(){ # dialect sql out
  if [ "$1" = table ]; then
    bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $2" > "$3" 2>&1
  else
    bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "$2" > "$3" 2>&1
  fi
  grep -vE '^(WARNING|Warning)' "$3" > "$3.c" && mv "$3.c" "$3"
}

matrix(){ # state
  local st=$1
  for dia in tree table; do
    for sql in "show cluster" "show datanodes" "show confignodes"; do
      local tag; tag=$(echo "$sql" | tr ' ' '_')
      run_cli "$dia" "$sql" "$OUT/${st}-cli-${dia}-${tag}.out"
      printf "%-9s cli     %-5s %-18s COLS=%s\n" "$st" "$dia" "$tag" "$(cols_cli "$OUT/${st}-cli-${dia}-${tag}.out")"
      for ifc in session jdbc; do
        run_java "$ifc" "$dia" "$sql" "$OUT/${st}-${ifc}-${dia}-${tag}.out"
        printf "%-9s %-7s %-5s %-18s %s\n" "$st" "$ifc" "$dia" "$tag" "$(head -n1 "$OUT/${st}-${ifc}-${dia}-${tag}.out")"
      done
    done
  done
}

echo "########## 基线 ##########"; matrix baseline
echo "########## ReadOnly ##########"
bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SYSTEM TO READONLY ON CLUSTER"
sleep 8; matrix readonly
echo "########## 恢复 ##########"
bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SYSTEM TO RUNNING ON CLUSTER"
sleep 8; matrix restored
