#!/bin/bash
# ============================================================================
# CRUD 专项 skill —— **离线纯桩**干跑（不连集群、不启停、不跑真 SQL）
#
#   用途：在没有集群（或严禁碰集群）的情况下，验证用例脚本的**代码路径与断言**是否真的会触发。
#   它把本 skill 的真实用例文件 + 桩 lib/桩 CLI 组装到 $STUB_ROOT（默认 /tmp/cr14_stub）后执行：
#     $STUB_ROOT/cases/common/cr_load_pipe_last.sh   ← 真实用例（每次运行都从 skill 复制，不会过期）
#     $STUB_ROOT/lib/common.sh  lib/cmp.sh           ← 桩（假 ssh/假 SQL/假集群生命周期）
#     $STUB_ROOT/lib/crud_ext.sh                     ← 真实文件（CRUD 日志判据层）
#     $STUB_ROOT/bin/fakecli.sh                      ← 假 CLI（只认 CR-14 用到的语句）
#     $STUB_ROOT/conf/env.conf                       ← 桩环境（3C3D 拓扑的假配置）
#
#   四种模式（对应用例里的关键断言，**故意让"坏产品行为"出现**来证明断言不是摆设）：
#     ok         正常产品行为（restart-only）       ⇒ 期望 RESULT PASS / fail_flag=0
#     hotapply   SET CONFIGURATION 立即生效（坏）   ⇒ 期望 "未重启但运行期生效值已变成…" FAIL
#     norestart  重启不应用配置（坏）               ⇒ 期望 "S1：… 生效值不一致" FAIL
#     stale      load 后不更新 LastCache（坏）      ⇒ 期望 S5 "load 后立即 LAST == CLEAR CACHE 真值" FAIL
#
#   用法（在 99.80 或任何有 bash 的机器上）：
#     bash tools/stub_offline/run.sh            # 跑 4 个模式并打印汇总
#     bash tools/stub_offline/run.sh ok         # 只跑 ok 模式
#   ⚠️ 桩 lib 只提供 CR-14 用到的接口；**换 CR-14 的用例逻辑时要同步桩**（否则桩会缺函数）。
#   ⚠️ 桩目录里的 `common.sh`/`cmp.sh`/`env.conf` 与真 lib **同名但不同内容**，只用于离线干跑。
# ============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
ROOT="${STUB_ROOT:-/tmp/cr14_stub}"
CASE="cases/common/cr_load_pipe_last.sh"
ONLY="${1:-all}"

assemble(){
  rm -rf "$ROOT"
  mkdir -p "$ROOT/cases/common" "$ROOT/lib" "$ROOT/conf" "$ROOT/bin" "$ROOT/results"
  cp -f "$HERE/lib/common.sh" "$HERE/lib/cmp.sh" "$ROOT/lib/"
  cp -f "$SKILL/lib/crud_ext.sh" "$ROOT/lib/"                       # 真实文件
  cp -f "$HERE/conf/env.conf" "$ROOT/conf/"
  cp -f "$HERE/bin/fakecli.sh" "$ROOT/bin/"; chmod +x "$ROOT/bin/fakecli.sh"
  cp -f "$SKILL/$CASE" "$ROOT/$CASE"                                # 真实用例（每次复制）
  echo "== 组装桩环境 $ROOT（用例来自 $SKILL/$CASE）=="
  ( cd "$ROOT" && for f in lib/common.sh lib/cmp.sh lib/crud_ext.sh bin/fakecli.sh "$CASE"; do
      bash -n "$f" && echo "  [ok] bash -n $f" || echo "  [FAIL] bash -n $f"; done )
}

run_mode(){ local mode=$1 out=$2 extra=${3:-}
  pkill -f 'cr_load_pipe_las[t]' 2>/dev/null || true
  rm -rf "$ROOT/state" "$ROOT/results"
  mkdir -p "$ROOT/results"
  # shellcheck disable=SC2086
  env STUB_MODE="$mode" $extra CR14_LOAD_SEC="${CR14_LOAD_SEC:-30}" CR14_WAIT_FILE_SEC="${CR14_WAIT_FILE_SEC:-10}" \
      CR14_FILES="${CR14_FILES:-2}" CR14_QN="${CR14_QN:-3}" CR14_BUDGET_DEVS="${CR14_BUDGET_DEVS:-64}" \
      timeout "${STUB_TIMEOUT:-600}" bash "$ROOT/$CASE" > "$out" 2>&1
  echo "########## STUB_MODE=$mode $extra → $out ##########"
  grep -E '\] RESULT ' "$out" || echo "  （没有 RESULT 行：脚本可能在中途出错，看 $out）"
  echo "  真实 FAIL 断言 = $(grep -cE '\] FAIL ' "$out") 条；WARN = $(grep -cE '\] WARN ' "$out") 条（WARN 不计入 fail_flag）"
  grep -E '\] FAIL ' "$out" | head -6 | sed 's/^/    /'
  echo
}

assemble
case "$ONLY" in
  all) run_mode ok "$ROOT/../cr14_stub_ok.out"
       run_mode hotapply "$ROOT/../cr14_stub_hotapply.out"
       run_mode norestart "$ROOT/../cr14_stub_norestart.out"
       run_mode ok "$ROOT/../cr14_stub_stale.out" 'STUB_STALE=1'
       echo "########## ok 模式关键证据（S3 双证 / S6 频繁 Load / S7 预算 / S8 权限 / R-58 方向 / Pipe）##########"
       grep -E '\] (PASS|FAIL) +(S[0-9]|R-58 方向)|Pipe 对端|CRUD 正证据|SET .*restart is required' "$ROOT/../cr14_stub_ok.out" | head -50 ;;
  *)   run_mode "$ONLY" "$ROOT/../cr14_stub_${ONLY}.out" ;;
esac
