#!/bin/bash
# =============================================================================
# 收集 3C5D 全部节点（3 CN + 5 DN）的完整日志与现场信息，打包给研发
#
#   用法:  bash tools/collect_logs.sh <tag> [版本目录名]
#   产出:  logs/<tag>_<时间戳>/           每节点一个子目录
#          logs/<tag>_<时间戳>.tar.gz     可直接发给研发
#
#   收集内容（每个节点）:
#     - logs/log_confignode_*.log / log_datanode_*.log（含 .out 与滚动文件）
#     - conf/iotdb-system.properties、iotdb-common.properties（复现配置）
#     - 进程/端口/磁盘/JVM 基本信息
#     - cn/dn 的 start 脚本输出（/tmp/*.start，若存在）
# =============================================================================
set -uo pipefail

CN_NODES="${CN_NODES:-172.20.70.5 172.20.70.4 172.20.70.26}"
DN_NODES="${DN_NODES:-172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30}"
SSH_USER="${SSH_USER:-cluster}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no}"
DB_PARENT_DIR="${DB_PARENT_DIR:-/data/iotdb}"
SHELL_CLIENT_DIR="${SHELL_CLIENT_DIR:-/data1/iotdb/testdb}"

TAG="${1:-repro}"
VER="${2:-$(ls -1t "$DB_PARENT_DIR" 2>/dev/null | grep -E '^v[0-9]' | head -1)}"
STAMP="$(date +%Y%m%d_%H%M%S)"
BASE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$BASE/logs/${TAG}_${STAMP}"
mkdir -p "$OUT"

sshx(){ local h=$1; shift; ssh -n $SSH_OPTS "$SSH_USER@$h" "$@"; }

echo "版本: $VER"
echo "输出: $OUT"

# ---------- 集群概览 ----------
CLI="$SHELL_CLIENT_DIR/$VER/sbin/start-cli.sh"
{
  echo "## 收集时间: $(date '+%F %T')"
  echo "## 版本目录: $VER"
  echo
  echo "### show cluster"
  [ -x "$CLI" ] && timeout 60 "$CLI" -h "${DN_NODES%% *}" -p 6667 -u root -pw "${ROOT_PW:-TimechoDB@2021}" -e "show cluster;" 2>&1 | grep -v setlocale
  echo
  echo "### show cluster details"
  [ -x "$CLI" ] && timeout 60 "$CLI" -h "${DN_NODES%% *}" -p 6667 -u root -pw "${ROOT_PW:-TimechoDB@2021}" -e "show cluster details;" 2>&1 | grep -v setlocale
  echo
  echo "### 各节点配置的版本"
  for h in $(printf '%s\n' $CN_NODES $DN_NODES | sort -u); do
    printf -- "- %s: %s\n" "$h" "$(sshx "$h" "ls -1d $DB_PARENT_DIR/$VER 2>/dev/null && grep -m1 '^dn_rpc_address=' $DB_PARENT_DIR/$VER/conf/iotdb-system.properties 2>/dev/null" 2>/dev/null | tr '\n' ' ')"
  done
} >"$OUT/00_cluster_overview.txt" 2>&1

# ---------- 每节点收集 ----------
collect_node(){
  local h=$1
  local role=$2
  local dst="$OUT/${h}_${role}"
  mkdir -p "$dst"
  sshx "$h" "
    D=$DB_PARENT_DIR/$VER
    echo '## hostname:' \$(hostname)
    echo '## date:' \$(date '+%F %T')
    echo '## uptime:'; uptime 2>/dev/null
    echo '## java procs:'; ps -eo pid,rss,etime,args 2>/dev/null | grep -E '^ *[0-9]+ .*com\.timecho\.iotdb' | grep -v grep
    echo '## listen ports:'; (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | head -30
    echo '## disk:'; df -h \$D 2>/dev/null
    echo '## version dir:'; ls -1d \$D 2>/dev/null
  " >"$dst/00_host_info.txt" 2>&1

  # 配置
  sshx "$h" "cat $DB_PARENT_DIR/$VER/conf/iotdb-system.properties 2>/dev/null" >"$dst/10_iotdb-system.properties" 2>/dev/null
  sshx "$h" "cat $DB_PARENT_DIR/$VER/conf/iotdb-common.properties 2>/dev/null" >"$dst/11_iotdb-common.properties" 2>/dev/null
  sshx "$h" "cat $DB_PARENT_DIR/$VER/conf/datanode-env.sh 2>/dev/null | grep -vE '^\s*#' | grep -v '^\s*$'" >"$dst/12_datanode-env.sh" 2>/dev/null
  sshx "$h" "cat $DB_PARENT_DIR/$VER/conf/confignode-env.sh 2>/dev/null | grep -vE '^\s*#' | grep -v '^\s*$'" >"$dst/13_confignode-env.sh" 2>/dev/null

  # 日志（全部，含 .out / 滚动）
  mkdir -p "$dst/logs"
  local files=""
  files=$(sshx "$h" "ls -1 $DB_PARENT_DIR/$VER/logs/*.log $DB_PARENT_DIR/$VER/logs/*.out 2>/dev/null" 2>/dev/null)
  local f
  for f in $files; do
    sshx "$h" "sudo cat $f 2>/dev/null || cat $f 2>/dev/null" >"$dst/logs/$(basename "$f")" 2>/dev/null
  done

  # 用例在故障注入时会把 DN 日志 mv 到 logs/logs_stop_remove_coord_<ts>
  # —— 这是"故障发生前/瞬间"的 DN 现场，研发最需要，必须单独收。
  local moved
  moved=$(sshx "$h" "sudo ls -1d $DB_PARENT_DIR/$VER/logs/logs_stop_remove_coord_* 2>/dev/null" 2>/dev/null)
  local md
  for md in $moved; do
    local bname; bname=$(basename "$md")
    mkdir -p "$dst/moved_logs/$bname"
    local mf
    for mf in $(sshx "$h" "sudo ls -1 $md/* 2>/dev/null" 2>/dev/null); do
      sshx "$h" "sudo cat $mf 2>/dev/null" >"$dst/moved_logs/$bname/$(basename "$mf")" 2>/dev/null
    done
    echo "  [$h/$role] 已收 mv 走的日志: $bname"
  done

  # 启动脚本输出（崩溃现场常在 /tmp/*.start）
  local starts=""
  starts=$(sshx "$h" "ls -1 /tmp/cn_*.start /tmp/dn_*.start /tmp/*_cn_*.log /tmp/*_dn_*.log 2>/dev/null" 2>/dev/null)
  for f in $starts; do
    sshx "$h" "sudo cat $f 2>/dev/null" >"$dst/logs/$(basename "$f")" 2>/dev/null
  done

  echo "  [$h/$role] 日志 $(ls -1 "$dst/logs" 2>/dev/null | wc -l) 个文件, $(du -sh "$dst" 2>/dev/null | cut -f1)"
}

for h in $CN_NODES; do collect_node "$h" CN; done
for h in $DN_NODES; do collect_node "$h" DN; done

# ---------- 打包 ----------
cd "$BASE/logs" && tar czf "${TAG}_${STAMP}.tar.gz" "$(basename "$OUT")" 2>/dev/null
echo
echo "完成: $OUT"
echo "包:   $BASE/logs/${TAG}_${STAMP}.tar.gz ($(du -sh "$BASE/logs/${TAG}_${STAMP}.tar.gz" 2>/dev/null | cut -f1))"
