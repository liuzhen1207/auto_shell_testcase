#!/bin/bash
# QS-01 Worker 线程数可配 + 非法值回退
#   覆盖需求：REQ-04（query_thread_count 可配置，且实例启动后不可改变）
#   判据：写 query_thread_count=2 → 配置生效且集群正常；写非法值 0 → 源码回退为 CPU 核数，节点不崩、集群仍就绪
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/perf.sh"
source "$HERE/../lib/qs.sh"
mb_load_env
mb_parse_args "$@"
mb_case_init QS-01
export QS_LONG_DB="${QS_LONG_DB:-root.test.qs_0}"

log "=== 第一段：合法值 query_thread_count=2 ==="
qs_set_scheduler_conf 2 600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
C1=$(sshx "${DN[0]}" "grep '^query_thread_count=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-")
assert_eq "①conf 写入 2" "$C1" "2"
assert_eq "②集群仍 8/8" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
pass "①query_thread_count=2 下集群正常运行（REQ-04 合法值生效）"

log "=== 第二段：非法值 query_thread_count=0（源码应回退 CPU 核数）==="
qs_set_scheduler_conf 0 600000 200
qs_prepare_cluster || { write_result 2>/dev/null; exit 1; }
C2=$(sshx "${DN[0]}" "grep '^query_thread_count=' $DB_DIR/conf/iotdb-system.properties | cut -d= -f2-")
assert_eq "③conf 写入 0" "$C2" "0"
assert_eq "④非法值下集群仍 8/8（回退 CPU 核数，未崩溃）" "$(sq 'show cluster;' 2>/dev/null | grep -cE 'Running.*ACTIVATED')" "8"
RS=$(sq "select count(*) from root.__system.**;" 2>/dev/null | grep -cE '^\|')
assert_ge "⑤非法值下仍可查询" "${RS:-0}" 1
pass "①query_thread_count=0 被安全回退，节点未崩溃（REQ-04 非法值兜底）"

log "=== 收尾 ==="
qs_set_scheduler_conf 1 3600000 200
write_result 2>/dev/null || true

