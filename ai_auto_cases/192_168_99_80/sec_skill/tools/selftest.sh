#!/bin/bash
# ============================================================================
# sec_skill 自检（不依赖集群）：语法、用例注册表、关键 helper 存在性
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ok=0; failed=0
chk(){ local name=$1 rc=$2; if [ "$rc" -eq 0 ]; then ok=$((ok+1)); echo "  ok   $name"; else failed=$((failed+1)); echo "  FAIL $name"; fi; }

echo "== 1) bash 语法 =="
for f in "$ROOT"/lib/*.sh "$ROOT"/tools/*.sh "$ROOT"/cases/*/*.sh; do
  bash -n "$f" 2>/dev/null; chk "语法 $(basename "$f")" $?
done

echo "== 2) 用例注册表 vs 文件 =="
for id in SEC-01 SEC-02 SEC-03 SEC-04 SEC-05 SEC-06 SEC-07 SEC-08 SEC-09; do
  grep -q "\"$id\"" "$ROOT/tools/run_all.sh"; chk "注册 $id" $?
done
for f in "$ROOT"/cases/*/*.sh; do
  grep -q 'sec_case_init' "$f"; chk "用例含 sec_case_init $(basename "$f")" $?
done

echo "== 3) helper 存在性 =="
for fn in sec_case_init sec_case_finish sec_conf_get sec_conf_set sec_user_create sec_user_alter sec_user_drop \
          sec_login_ok sec_login_msg sec_log_mark sec_check_logs sec_check_password_leak sec_replica_consistency \
          sec_start_cluster sec_stop_cluster sec_clock_shift; do
  grep -q "^$fn()" "$ROOT/lib/common.sh" || grep -q "^$fn(){" "$ROOT/lib/common.sh"; chk "helper $fn" $?
done

echo "== 4) 需求点覆盖映射（每个需求点至少一条用例引用）=="
mapfile -t fc < <(cat "$ROOT"/cases/*/*.sh 2>/dev/null)
for pair in "a:长度:sec_password_length.sh" "b/c/d:复杂度:sec_password_complexity.sh" "e:用户名:sec_password_username.sh" \
            "g:重用:sec_password_reuse.sh" "f:有效期:sec_password_expire.sh"; do
  kw="${pair%%:*}"; file="${pair##*:}"
  ls "$ROOT/cases"/*/"$file" >/dev/null 2>&1; chk "覆盖 $kw -> $file" $?
done

echo
echo "== 结果：ok=$ok failed=$failed =="
[ "$failed" -eq 0 ] && exit 0 || exit 1
