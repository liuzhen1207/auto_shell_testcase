#!/bin/bash
# ============================================================================
# 编译并分发测试用 UDF / Trigger jar
#
#   在 99.80（跳板机）上执行：bash assets/udf/build_and_deploy.sh
#
# 做的事：
#   1) 把 assets/udf/src 下的源码送到第一个节点，用**服务端自己的 jar**做 classpath 编译；
#   2) 打包成 mdskill.jar，并分发到所有节点的固定路径 /data/iotdb/udf_md/mdskill.jar
#      （CREATE FUNCTION/TRIGGER 用 USING URI 'file:///data/iotdb/udf_md/mdskill.jar' 引用，
#        集群里每个节点都必须有这个文件，所以统一放同一路径）；
#   3) 顺带放到 ext/udf 与 ext/trigger（备用：IoTDB 启动时会扫描这两个目录）。
#
# 只依赖 JDK（javac/jar）+ ssh/scp，不需要 maven。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="$(cd "$HERE/../.." && pwd)"
if [ -f "$AUTO_DIR/lib/common.sh" ]; then
  . "$AUTO_DIR/lib/common.sh"
  md_load_env
else
  # 允许在没有 lib 的环境下独立运行
  CN_NODES="${CN_NODES:-192.168.99.77 192.168.99.78 192.168.99.79}"
  V_TESTDB="${V_TESTDB:-v20121rc5_1003_aaf460d}"
  DB_PARENT_DIR="${DB_PARENT_DIR:-/data/iotdb}"
  SSH_USER="${SSH_USER:-root}"
  SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15}"
  DB_DIR="$DB_PARENT_DIR/$V_TESTDB"
  read -ra DN <<<"$CN_NODES"
fi

UD_F_DIR="${UD_SRC_DIR:-$HERE/src}"
JAR_NAME="mdskill.jar"
REMOTE_DIR="/data/iotdb/udf_md"          # 集群统一路径（USING URI 用）
BUILD_HOST="${DN[0]}"
BUILD_DIR="/tmp/mdskill_build"

server_jar="$DB_DIR/lib/timechodb-server-2.0.12.1.jar"
[ -f "$UD_F_DIR/mdskill/MdUdtf.java" ] || { echo "缺少源码目录 $UD_F_DIR/mdskill"; exit 2; }

echo "=== 1) 源码送到 $BUILD_HOST 并用服务端 jar 编译 ==="
ssh $SSH_OPTS "$SSH_USER@$BUILD_HOST" "rm -rf $BUILD_DIR && mkdir -p $BUILD_DIR/src $BUILD_DIR/classes" || exit 1
scp -q -r "$UD_F_DIR/mdskill" "$SSH_USER@$BUILD_HOST:$BUILD_DIR/src/" || exit 1
ssh $SSH_OPTS "$SSH_USER@$BUILD_HOST" "cd $BUILD_DIR && javac -nowarn -cp '$server_jar' -d classes src/mdskill/*.java && jar cf $JAR_NAME -C classes . && ls -l $JAR_NAME && jar tf $JAR_NAME | head" || exit 1

echo "=== 2) 取回并分发到所有节点 $REMOTE_DIR/$JAR_NAME ==="
rm -f "/tmp/$JAR_NAME"
scp -q "$SSH_USER@$BUILD_HOST:$BUILD_DIR/$JAR_NAME" "/tmp/$JAR_NAME" || exit 1
for h in "${DN[@]}"; do
  ssh $SSH_OPTS "$SSH_USER@$h" "mkdir -p $REMOTE_DIR $DB_DIR/ext/udf $DB_DIR/ext/trigger" || { echo "建目录失败 $h"; exit 1; }
  scp -q "/tmp/$JAR_NAME" "$SSH_USER@$h:$REMOTE_DIR/$JAR_NAME" || { echo "分发失败 $h"; exit 1; }
  scp -q "/tmp/$JAR_NAME" "$SSH_USER@$h:$DB_DIR/ext/udf/$JAR_NAME"
  scp -q "/tmp/$JAR_NAME" "$SSH_USER@$h:$DB_DIR/ext/trigger/$JAR_NAME"
  echo "  $h -> $(ssh $SSH_OPTS "$SSH_USER@$h" "ls -l $REMOTE_DIR/$JAR_NAME | awk '{print \$5\" bytes\"}'")"
done
echo "=== 完成：$REMOTE_DIR/$JAR_NAME（各节点一致） ==="
