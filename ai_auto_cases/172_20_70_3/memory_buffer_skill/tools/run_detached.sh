#!/bin/bash
# 在客户端机 172.20.70.3 上"可靠地"跑整套用例。
#
# 背景（实测）：`setsid nohup bash tools/run_all.sh ... &` 之后再断开 ssh，
#   用例会在写入阶段被 SIGKILL（rc=137），dmesg 无 OOM 记录 —— 属会话/进程组回收。
#   同样的命令在前台、或放在 screen/tmux 里，则 100% 正常（MB-03 前台实测 PASS）。
#
# 用法：
#   bash tools/run_detached.sh --set regression
#   bash tools/run_detached.sh --set quick --consensus IoTConsensusV2
#   screen -r mb        # 看进度；Ctrl-A D 退出但不结束
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SESS=mb
ARGS="$*"
[ -z "$ARGS" ] && ARGS="--set regression"

if command -v screen >/dev/null 2>&1; then
  screen -S "$SESS" -X quit 2>/dev/null || true
  sleep 1
  screen -dmS "$SESS" bash -lc "cd '$HERE/..' && bash tools/run_all.sh $ARGS > /tmp/mb_screen.log 2>&1; echo EXIT=\$? >> /tmp/mb_screen.log"
  echo "已在 screen 会话 [$SESS] 中启动：bash tools/run_all.sh $ARGS"
  echo "查看：screen -r $SESS    （Ctrl-A D 退出查看）"
  echo "日志：/tmp/mb_screen.log    结果：../results/"
  exit 0
fi
if command -v tmux >/dev/null 2>&1; then
  tmux kill-session -t "$SESS" 2>/dev/null || true
  tmux new-session -d -s "$SESS" "cd '$HERE/..' && bash tools/run_all.sh $ARGS > /tmp/mb_screen.log 2>&1; echo EXIT=\$? >> /tmp/mb_screen.log"
  echo "已在 tmux 会话 [$SESS] 中启动：bash tools/run_all.sh $ARGS"
  echo "查看：tmux attach -t $SESS"
  exit 0
fi
echo "!! 本机没有 screen/tmux。请改为让发起端 ssh 一直挂着，例如：" >&2
echo "   ssh cluster@172.20.70.3 'cd <skill> && bash tools/run_all.sh $ARGS'" >&2
echo "   （不要用 setsid nohup ... & 再断开连接）" >&2
exit 1
