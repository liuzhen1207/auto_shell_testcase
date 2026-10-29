#!/bin/bash
# ============================================================================
# 编译"未排序 TsFile 生成器"并把 class 分发到目标 DataNode
#
#   load 读的是**执行节点本地磁盘**上的文件，所以 class 必须放到该 DN 上。
#   （实测：文件只放在 .77 时 load 成功，三副本各得到 1 个 TsFile）
#
# 用法（由用例调用，环境变量）：
#   V_TESTDB=<版本目录名> GEN_TARGET_NODE=<节点IP> bash build_gen.sh
# 可选：
#   GEN_JAR         服务端 jar 路径（默认 <DB_PARENT_DIR>/testdb/<ver>/lib/timechodb-server-2.0.12.1.jar）
#   GEN_REMOTE_DIR  目标节点上的 class 目录（默认 /tmp/c33gen）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="${V_TESTDB:?build_gen.sh 需要 V_TESTDB}"
JAR="${GEN_JAR:-/data/iotdb/testdb/$V/lib/timechodb-server-2.0.12.1.jar}"
[ -f "$JAR" ] || JAR="/data/iotdb/$V/lib/timechodb-server-2.0.12.1.jar"
[ -f "$JAR" ] || { echo "[build_gen] 找不到服务端 jar（试过 $JAR）" >&2; exit 1; }
BUILD="$HERE/build"
mkdir -p "$BUILD"

javac -encoding UTF-8 -cp "$JAR" -d "$BUILD" "$HERE/UnsortedTsFileGen.java" || {
  echo "[build_gen] javac 失败" >&2; exit 1; }
ls -l "$BUILD"/UnsortedTsFileGen*.class >&2 || exit 1

TARGET="${GEN_TARGET_NODE:-}"
if [ -z "$TARGET" ]; then
  echo "[build_gen] 未指定 GEN_TARGET_NODE，只编译不分发" >&2
  echo "$BUILD"
  exit 0
fi
RMT="${GEN_REMOTE_DIR:-/tmp/c33gen}"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15}"
# shellcheck disable=SC2086
ssh -n $SSH_OPTS "$SSH_USER@$TARGET" "mkdir -p $RMT && rm -f $RMT/UnsortedTsFileGen*.class" || exit 1
# shellcheck disable=SC2086
scp $SSH_OPTS "$BUILD"/UnsortedTsFileGen*.class "$SSH_USER@$TARGET:$RMT/" >/dev/null || exit 1
n=$(ssh -n $SSH_OPTS "$SSH_USER@$TARGET" "ls -1 $RMT/UnsortedTsFileGen*.class | wc -l" | tr -dc '0-9')
[ "${n:-0}" -ge 1 ] || { echo "[build_gen] 分发失败：$TARGET:$RMT 没有 class" >&2; exit 1; }
echo "[build_gen] 已分发 $n 个 class 到 $TARGET:$RMT（jar=$JAR）" >&2
echo "$BUILD"
