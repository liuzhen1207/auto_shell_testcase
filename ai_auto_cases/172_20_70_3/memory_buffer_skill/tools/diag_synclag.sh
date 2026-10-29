#!/usr/bin/env bash
# =============================================================================
# diag_synclag.sh —— IoTConsensus / IoTConsensusV2 的 syncLag 诊断脚本
#
# 用途：判断某个 (DataNode, DataRegion) 的 syncLag 是「真实积压」还是「指标记账问题」。
#       本次 RC10 上报的形态是：窗口内恒定为同一个非零值（多为 1），与写入量无关。
#
# 独立运行，只依赖 curl / awk / sort，不需要部署 skill 的其他文件。
#
# 用法：
#   ./diag_synclag.sh
#   DN_LIST="172.20.70.4 172.20.70.26" ROUNDS=12 INTERVAL=10 ./diag_synclag.sh
#   METRIC_PORT=9092 ROUNDS=30 INTERVAL=10 ./diag_synclag.sh   # 更长的观察窗口
#
# 参数（环境变量）：
#   DN_LIST      要采集的 DataNode IP 列表，空格分隔
#                默认：172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30
#   METRIC_PORT  DataNode 指标端口，默认 9092
#   ROUNDS       采样轮数，默认 12
#   INTERVAL     采样间隔秒数，默认 10
#   CLI          可选：start-cli.sh 路径。给出后会补充 region→库名/角色 的映射
#   HOST         可选：CLI 连接用的主机，默认取 DN_LIST 的第一个
#
# 判定规则（逐 (节点,region) 统计窗口内的取值）：
#   ZERO      始终为 0                        → 正常
#   STUCK     非零且窗口内恒定为同一值        → 疑似指标记账问题（本次上报形态）
#   GROWING   非零且末值 > 首值                → 真实积压，需要看 pipe 队列
#   DRAINING  非零且末值 < 首值                → 正在追赶，继续观察
#   FLUCT     非零但无单调趋势                 → 需结合 pipe 队列判断
# =============================================================================
set -uo pipefail

DN_LIST="${DN_LIST:-172.20.70.4 172.20.70.26 172.20.70.14 172.20.70.27 172.20.70.30}"
METRIC_PORT="${METRIC_PORT:-9092}"
ROUNDS="${ROUNDS:-12}"
INTERVAL="${INTERVAL:-10}"
CLI="${CLI:-}"
HOST="${HOST:-$(echo "$DN_LIST" | awk '{print $1}')}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/raw.tsv"
: >"$RAW"

echo "=== syncLag 诊断 ==="
echo "  节点($(echo "$DN_LIST" | wc -w) 个): $DN_LIST"
echo "  端口: $METRIC_PORT   轮数: $ROUNDS   间隔: ${INTERVAL}s   总窗口: $((ROUNDS * INTERVAL))s"
echo

# ---------------------------------------------------------------------------
# 逐轮采集：输出  round<TAB>node<TAB>region<TAB>value
# 指标形如：
#   iot_consensus_v2{cluster="...",nodeType="DATANODE",nodeId="6",
#                    name="IoTConsensusV2ServerImpl",region="DataRegion[9]",
#                    type="syncLag",} 0.0
# ---------------------------------------------------------------------------
collect() {
  local round=$1 h line v reg
  for h in $DN_LIST; do
    curl -s -m 6 "http://$h:$METRIC_PORT/metrics" 2>/dev/null \
      | grep 'type="syncLag"' \
      | while IFS= read -r line; do
          v="${line##* }"
          reg="$(printf '%s' "$line" | grep -oE 'region="DataRegion\[[0-9]+\]"' | grep -oE '[0-9]+')"
          [ -n "$reg" ] || continue
          printf '%s\t%s\t%s\t%s\n' "$round" "$h" "$reg" "$v"
        done >>"$RAW"
  done
}

for i in $(seq 1 "$ROUNDS"); do
  printf '  采样 %d/%d @ %s\n' "$i" "$ROUNDS" "$(date '+%H:%M:%S')"
  collect "$i"
  [ "$i" -lt "$ROUNDS" ] && sleep "$INTERVAL"
done

if [ ! -s "$RAW" ]; then
  echo
  echo "!! 未采集到任何 syncLag 指标。请检查："
  echo "   1) 该版本是否使用 IoTConsensus / IoTConsensusV2（V1 的指标名是 iot_consensus）"
  echo "   2) 端口是否正确（默认 9092）"
  echo "   3) 节点是否已激活并正常提供服务"
  exit 2
fi

# ---------------------------------------------------------------------------
# 聚合判定
# ---------------------------------------------------------------------------
AGG="$TMP/agg.tsv"
awk -F'\t' '
{
  key = $2 "\t" $3
  cnt[key]++
  v = $4 + 0
  if (!(key in first)) { first[key] = v; min[key] = v; max[key] = v; seen[key] = "" }
  last[key] = v
  if (v < min[key]) min[key] = v
  if (v > max[key]) max[key] = v
  # 记录出现过的小数位，用于判断“是否恒定”
  if (index(seen[key], "|" v "|") == 0) seen[key] = seen[key] "|" v "|"
  distinct[key]++
}
END {
  for (k in cnt) {
    split(k, p, "\t")
    node = p[1]; reg = p[2]
    n = split(seen[k], arr, "|") - 2     # 去首尾空串
    f = first[k]; l = last[k]; mn = min[k]; mx = max[k]
    if (mx == 0) { cls = "ZERO" }
    else if (n == 1) { cls = "STUCK" }
    else if (l > f) { cls = "GROWING" }
    else if (l < f) { cls = "DRAINING" }
    else { cls = "FLUCT" }
    printf "%s\t%s\t%s\t%.1f\t%.1f\t%.1f\t%d\n", cls, node, reg, f, l, mx, n
  }
}' "$RAW" | sort -k1,1 -k3,3n >"$AGG"

# region → 库名/角色（可选）
ROLE="$TMP/role.tsv"
: >"$ROLE"
if [ -n "$CLI" ] && [ -x "$CLI" ]; then
  timeout 40 "$CLI" -h "$HOST" -p 6667 -u root -pw TimechoDB@2021 -e "show regions;" 2>/dev/null \
    | awk -F'|' 'NR>2 {gsub(/ /,"",$2);gsub(/ /,"",$5);gsub(/ /,"",$11);gsub(/ /,"",$12);
                  if ($2 != "" && $5 != "") print $2"\t"$5"\t"$11"\t"$12}' >"$ROLE"
fi
role_of() { awk -F'\t' -v r="$1" '$1==r {printf "%s / %s", $2, $4; exit}' "$ROLE"; }

echo
echo "=== 结果（按判定分组）==="
printf '  %-9s %-16s %-8s %-22s %s\n' "判定" "节点" "region" "首值→末值(峰值)" "取值种类"
while IFS=$'\t' read -r cls node reg f l mx n; do
  extra=""
  if [ -s "$ROLE" ] && [ "$cls" != "ZERO" ]; then
    r="$(role_of "$reg")"
    [ -n "$r" ] && extra="  [$(printf '%s' "$r")]"
  fi
  printf '  %-9s %-16s %-8s %s→%s(峰值 %s)  %s 种%s\n' \
    "$cls" "$node" "r$reg" "$f" "$l" "$mx" "$n" "$extra"
done <"$AGG"

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
STUCK_N=$(awk -F'\t' '$1=="STUCK"' "$AGG" | wc -l | tr -d ' ')
GROW_N=$(awk -F'\t' '$1=="GROWING"' "$AGG" | wc -l | tr -d ' ')
NONZERO=$(awk -F'\t' '$1!="ZERO"' "$AGG" | wc -l | tr -d ' ')
TOTAL=$(wc -l <"$AGG" | tr -d ' ')

echo
echo "=== 结论 ==="
echo "  采集 series 总数: $TOTAL   非零: $NONZERO   恒定非零(STUCK): $STUCK_N   增长(GROWING): $GROW_N"
if [ "$STUCK_N" -gt 0 ]; then
  echo
  echo "  ⚠ 检测到 $STUCK_N 条「窗口内恒定非零」的 syncLag —— 与本次上报的形态一致："
  echo "    这类取值不随写入量变化、flush 后也不归零，通常不是真实待同步量，而是进度记账问题"
  echo "    （syncLag = leaderReplicateProgress − followerApplyProgress 的固定差）。"
  echo
  echo "  ⚠ 重要：该指标反向也会失真 —— 曾观察到 follower 真实缺少多个 TsFile 时 syncLag 仍为 0。"
  echo "    因此不能用 syncLag==0 作为「复制已完成」的判据。"
  echo
  echo "  建议下一步（定位根因必需）：临时暴露下面两个原始值，区分是 leader 多算还是 follower 少记："
  echo "    leaderReplicateProgress = ReplicateProgressDataNodeManager.getReplicateIndexForIoTV2(pipe)"
  echo "    followerApplyProgress   = IoTConsensusV2AsyncSink.getFollowerApplyProgress()"
elif [ "$GROW_N" -gt 0 ]; then
  echo
  echo "  ⚠ 存在持续增长的 syncLag，更像真实积压。请同时检查 pipe 队列与 Pipe 内存池："
  echo "    show pipes;                                  # 看 RemainingEventCount"
  echo "    grep PipeRuntimeOutOfMemoryException <datanode.log>"
fi
echo
echo "  原始数据: $RAW（脚本退出后会清理，需要留存请重定向输出到文件）"
