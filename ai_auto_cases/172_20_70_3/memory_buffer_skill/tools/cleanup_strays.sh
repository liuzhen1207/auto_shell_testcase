#!/bin/bash
# 手工清理"上一次被强杀后遗留的进程"与陈旧锁。
#   ⚠️ 只在本 skill **确定没有在跑**时执行；它会 kill 掉所有匹配的用例进程。
#   默认 dry-run，确认无误后加 --force 才真正 kill。
#
# ⚠️ 两个实测踩过的坑（2026-10-22，F-10 复测时被拖了很久）：
#   1) **pkill -f 的模式往往匹配不到真正的进程**：经 `/tmp/execjob.sh` 下发的脚本在远端
#      进程名是 `bash <skill>/runs/job.sh`，不是脚本自己的文件名。用
#      `pkill -f 'v2_cons.sh'` 会 0 命中，而那个脚本会**继续在后台反复 stop/start DataNode**，
#      与后续测量并发，把"停某节点后查询为 0"这类结论彻底污染（甚至出现自己杀自己）。
#   2) **pkill -f 'runs/job.sh' 会把自己的执行载体一起杀掉**（本脚本自身也是 job.sh 的子进程），
#      表现为脚本中途退出、后续清理命令不执行。
#   因此本脚本改为：**按 PID 判断**——排除自身与祖先进程，只清理运行时长超过阈值（默认 600s）的残留，
#   并且逐条打印 etime 供核对，不再依赖模糊的 pkill -f。
set -uo pipefail
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
MAXAGE="${2:-600}"     # 运行超过这个秒数的才算残留
SKILL="$(cd "$(dirname "$0")/.." && pwd)"

# 收集自身与所有祖先进程，避免自杀
SELF_CHAIN=" $(ps -o ppid= -p $$ | tr -d ' ') "
pid=$$; for _ in 1 2 3 4 5 6; do
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$ppid" ] || [ "$ppid" = "0" ] && break
  SELF_CHAIN="$SELF_CHAIN$ppid "
  pid=$ppid
done
SELF_CHAIN="$SELF_CHAIN$$ "

# etime → 秒
age_of(){ local et=$1 d h m s
  case "$et" in
    *-*) d=${et%%-*}; et=${et#*-}; h=${et%%:*}; et=${et#*:}; m=${et%%:*}; s=${et##*:}; echo $(( d*86400 + h*3600 + m*60 + s ));;
    *:*) h=${et%%:*}; et=${et#*:}; m=${et%%:*}; s=${et##*:}; echo $(( h*3600 + m*60 + s ));;
    *)   echo "${et:-0}";;
  esac
}

echo "=== 候选进程（用例脚本 / run_* / runs/job.sh）==="
FOUND=0
while read -r pid et rest; do
  [ -z "${pid:-}" ] && continue
  case "$SELF_CHAIN" in *" $pid "*) echo "  [跳过·自身或父进程] pid=$pid etime=$et"; continue;; esac
  age=$(age_of "$et")
  mark=""; [ "$age" -gt "$MAXAGE" ] && mark="  ← 超过 ${MAXAGE}s，判为残留"
  echo "  pid=$pid etime=$et (${age}s) ${rest:0:80}$mark"
  FOUND=$((FOUND+1))
done < <(ps -eo pid,etime,args | grep -E "(membuf_skill/(cases/common/mb_[0-9]+_|tools/run_(all|serial|until_done|perf)\.sh)|(skill_case|runs)/job\.sh)" | grep -v grep | awk '{print $1, $2, substr($0, index($0,$3))}')
[ "$FOUND" = "0" ] && echo "(无)"

if [ "$FORCE" = "1" ]; then
  echo "=== 清理超过 ${MAXAGE}s 的残留 ==="
  while read -r pid et rest; do
    [ -z "${pid:-}" ] && continue
    case "$SELF_CHAIN" in *" $pid "*) continue;; esac
    age=$(age_of "$et")
    if [ "$age" -gt "$MAXAGE" ]; then
      echo "  kill -9 $pid (etime=$et, ${age}s) ${rest:0:60}"
      kill -9 "$pid" 2>/dev/null
    fi
  done < <(ps -eo pid,etime,args | grep -E "(membuf_skill/(cases/common/mb_[0-9]+_|tools/run_(all|serial|until_done|perf)\.sh)|(skill_case|runs)/job\.sh)" | grep -v grep | awk '{print $1, $2, substr($0, index($0,$3))}')
  sleep 1
  rm -f "$SKILL/results/.run_all.lock" "$SKILL/results/.run_serial.lock"
  echo "已清理（含陈旧锁）"
else
  echo "（dry-run；加 --force 才会真正 kill 并删锁）"
fi
