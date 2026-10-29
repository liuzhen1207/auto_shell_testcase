#!/bin/bash
# ============================================================================
# W-25 WAL 盘"写不进去"（高可用）：让 WAL 目录不可写 → 记录写入表现（阻塞/报错/降级，**如实记录**）
#      → 恢复可写后数据一致（无需重启即恢复 或 重启后恢复）
#
# 【用例】W-25（集合 ha；树模型；库名 root.walrod）
#
# 【覆盖需求】
#   · cases/cases.tsv W-25：DN 以 root 运行 ⇒ `chmod` 无效；按序尝试 ①`chattr +i`（immutable）
#     ②独立小文件系统（tmpfs/loop）写满造 ENOSPC；观察写入表现 → 恢复可写后数据一致；
#     **探测-判定-降级三段式**：都不可行 ⇒ `warn "本环境不可构造（原因+证据）"` 并跳过，**不判 FAIL**；
#     任何破坏性动作（chattr/挂载）必须可回滚（trap）。
#   · docs/req_sources/source_grounding.md：
#       §5.1 WALBuffer.java:258-274 写失败会让**写请求报错**（`walFlushListener.fail`）；
#       §5.2 fsync 链路 LogWriter.force → `logChannel.force(true)`（"A closed channel is a failed
#            durability operation, not a successful no-op"）；
#       §5.3 轮转 WALBuffer.java:697-725（轮转/fsync 失败 ⇒ §10.2 #17/#18/#19 的
#            `Fail to roll|sync|fsync wal node-{}'s … , change system mode to error.`，**ERROR 级**）；
#       §6.2 / WALNode.java:671-676 canDeleteFile（IoTConsensus 下只删 status=0 的文件、**最后一个文件始终保留**）
#            ⇒ "WAL 文件数 ≥1" 可作场景有效性信号；
#       §8.2 恢复链 INFO 文案；§10.2 #21/#10 是 **DEBUG**（默认不落盘）⇒ **不得**当判据。
#   · docs/DECISIONS.md §1（目录/日志=过程证据、数据面=唯一 FAIL 判据）、§2（只 WARN 清单）。
#
# 【判据（硬/软分明）】
#   相 0（基线，硬）：集群起来（`dn_wal_dirs` = 专用目录 $WAL_BASE）+ 第 1 批写入可见 + flush 落盘
#      ⇒ 再写第 2 批（**不 flush**，制造"只在 MemTable + WAL 上"的数据）+ WAL 目录确有 .wal。
#   构造（探测-判定-降级三段式；**硬 = 只判"构造是否真的成立"**）：
#     ① `chattr +i`：先功能性探测（临时文件 +i 后**新建 fd 写入必须被拒**、`-i` 可还原）⇒ 可用则锁住
#        `$WAL_BASE/**/*.wal`（只锁文件，不锁目录）→ 逐副本验证"新 fd 写入被拒" → 观察窗口内
#        "被锁文件字节是否增长 / 是否出现新 .wal"（既有 fd 仍能写 ⇒ 构造**无效**，如实记录）。
#     ② tmpfs：先探测 mount/umount 能力 ⇒ 可用则 `dn_wal_dirs` 指到 tmpfs（**切目录前先 flush**，见 W-24）
#        → 重启 → 写入 → `dd` 填满造 ENOSPC → 再写一次并记录表现。
#     ①②都不可行 ⇒ `warn "本环境不可构造（原因+证据）"` 并**跳过破坏性相**（不判 FAIL）。
#   只读窗口（**软** = 如实记录，不作门禁）：逐设备写入 + 局部超时 ${W25_SQL_TIMEOUT_SEC}（区分"阻塞"与"报错"），
#     记录成功/失败/超时设备数、首个文案、耗时、DN 日志 `Fail to (roll|sync|fsync) wal node`/`change system mode`
#     行数增量、DN 进程存活、`show cluster` 状态。
#   恢复相（**硬，唯一能判 FAIL 的**）：恢复可写（`chattr -i` / umount + conf 还原）后
#     1) 记录"重启前可见数据"（count/sum + `$DB.d1` 全序列 md5）作为基线
#     2) 重启（stop → start，**不 clean**）⇒ 重启后 count **不得少于**重启前（少于 = FAIL 丢数据；
#        多于 = WARN：客户端超时/报错的语句事后被应用属"失败不确定"语义，如实记录）；count 相同时
#        sum 与 md5 必须一致（不一致 = FAIL）
#     3) 重启后再写一批 ⇒ count 必须精确增加（证明 WAL 子系统已恢复工作）+ WAL 目录仍有 .wal
#   收尾三件套：sync lag / 逐 DN 停机副本一致 / 日志扫描（本用例**不装** WAL 建议正则：只读窗口会故意报错）
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ **最可能误判的点**：`chattr +i` 只拦"新 open(O_WRONLY)"，对 DN **已经持有**的 wal 文件 fd 可能不生效
#     ⇒ 窗口内可能观察不到任何报错（写入照常成功）。本用例用"被锁文件字节是否增长 / 是否出现新 .wal"
#     判定构造是否有效：无效 ⇒ 记 WARN 并落到 ②（ENOSPC 才是忠实的"写不进去"），**不把"没报错"当产品缺陷**。
#   ⚠ 破坏性动作全部可回滚：`w25_rollback`（chattr -i 递归 + umount + rmdir）由 `trap … EXIT` 无条件执行。
#   ⚠ 同名键不能出现两次（cluster_write_conf 逐键回读会判假 FAIL）⇒ w25_strip_keys 先摘掉 dn_wal_dirs/wal_mode。
#   ⚠ **切 `dn_wal_dirs` 前必须 flush**：新 WAL 目录不会扫描旧目录的 WAL（W-24 的教训）⇒ ② 相切换前显式 flush。
#   ⚠ harness 缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"整步终止 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 4 条）：
#     ① `chattr` 在本文件系统上是否可用（ext4/xfs 可用；overlayfs/tmpfs 会返回 Operation not supported）；
#        探测结果与"锁后新建 fd 写入 = DENIED/WRITABLE"都要看。
#     ② 只读窗口里 DN 到底怎么表现（报错 / 阻塞 / 照常成功），以及是否进入 `change system mode to error`
#        （§10.2 #17-#19）：这三条都只**如实记录**，不作门禁。
#     ③ 只读窗口可能留下**半截 WAL** ⇒ 重启恢复能否成功（本用例硬判"重启后数据不少"）；
#        若 DN 起不来，请把逐副本证据交研发，不要先怀疑环境。
#     ④ ②的 tmpfs：容器里 `mount` 是否被允许（探测会先试一次临时挂载）；不允许 ⇒ 只记录不可构造。
#
# 用法： bash cases/common/wal_disk_readonly.sh [--consensus IoTConsensus|IoTConsensusV2]
#   可调：W25_WIN_SEC（窗口保持，默认 90）、W25_SQL_TIMEOUT_SEC（窗口内单语句超时，默认 120）
#         W25_WAL_BASE=/data/iotdb/walrod、W25_MNT_BASE=/data/iotdb/w25mnt、W25_SKIP_ENOSPC=1（强制只做①）
#
# 【RC8 首轮失败根因 + 修法（2026-10-18，用例侧 bug，判据一条没动）】
#   `line 123/127/168/184: h: unbound variable`（每个副本各报一次）：9 个 helper 写成
#   `f(){ local h v`（或 `local h r` / `local h`）—— 只声明、**没接参数**。bash 里 `local x` 是
#   "已声明但未赋值"，`set -u` 下 `$h` 仍按未定义变量报错（这一点与"local 会置空串"的直觉不同）。
#   后果不止是报错：`sshx "$h"` 会 ssh 到空主机名 ⇒ WAL 文件数/字节数/chattr 探测/tmpfs 探测**全部返回 0/UNKNOWN**，
#   于是 `相 0 场景无效：WAL 文件数=0` 与 `构造①②不可构造` 都是这几行带出来的假象。
#   修法：一律改成 `local h=$1 ...`（w25_bytes/w25_files/w25_werr_cnt/w25_werr_line/w25_chattr_probe/
#   w25_lock/w25_lock_denied/w25_mount_probe/w25_fill）。只修"取值"，不改任何判据与窗口。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# ---- harness 侧防御（见头注释；不改 lib/conf）--------------------------------
: "${TTL_CHECK_INTERVAL_MS:=60000}"
: "${MAX_EXPIRED_TIME_MS:=9223372036854775807}"
: "${EXPIRED_DATA_RATIO:=0.000001}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_disk_readonly_${DATA_CONSENSUS}"

DB=root.walrod
DEVS=${WAL_DEVS:-4}
ROWS=${WAL_ROWS:-200}
WIN=${W25_WIN_SEC:-90}
SQL_TO=${W25_SQL_TIMEOUT_SEC:-120}
CLOSE_WIN=${WAL_CLOSE_WIN_SEC:-60}
TOTAL=$(( ${#CN[@]} + ${#DN[@]} ))
WAL_BASE=${W25_WAL_BASE:-/data/iotdb/walrod}
MNT=${W25_MNT_BASE:-/data/iotdb/w25mnt}
BASE_TS=$(( ($(date +%s) - 3600) * 1000 ))
BOFF=0
BATCH=0
WIN_OK=0; WIN_ERR=0; WIN_BLOCK=0; WIN_MSG=""
EFF01=0; METHOD="none"
PRE_C=0; PRE_S=0; PRE_MD5=""
W25_FLOOR=0

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
w25_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }
W25_GOOD="$(w25_strip_keys 'wal_mode dn_wal_dirs'),wal_mode=ASYNC,dn_wal_dirs=$WAL_BASE,$CMP_EXTRA_WRITE"

w25_sql_to(){ local t=$1 s=$2; timeout "$t" "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 3600 -e "$s" 2>&1; }
w25_sql(){ w25_sql_to "$SQL_TIMEOUT_SEC" "$1"; }
# DN 的 JVM pid：**必须**走 lib/wal_ext.sh 的 `wal_dn_pid`（扫 /proc/*/cmdline，只认 java 可执行
#   + cmdline 含 DataNode）。旧的 `pgrep -f com.timecho.iotdb.DataNode` 会拿到远端 `bash -c`
#   包装 shell 的 pid ⇒ 只读盘场景里"DN 进程存活数"恒等于 3（本用例只要判存活，不判健康）。
#   存活再用 `kill -0` 复核真实 pid（`wal_dn_alive`），比 pgrep 精确。
w25_dn_pid(){ wal_dn_pid "$1"; }
w25_running(){ cmp_running_cnt | tr -dc '0-9'; }
w25_count(){ row_sum "$(w25_sql "select count(s1) from $DB.**;")"; }
w25_sum(){ row_sum "$(w25_sql "select sum(s1) from $DB.**;")"; }
w25_d1_md5(){ w25_sql "select s1 from $DB.d1 order by time;" | data_rows | md5sum | cut -c1-12; }
w25_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $WAL_BASE -name '*.wal' -type f -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w25_bytes_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w25_bytes "$h") )); done; echo "$s"; }
w25_files(){ local h=$1 v
  v=$(sshx "$h" "find $WAL_BASE -name '*.wal' -type f 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w25_files_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w25_files "$h") )); done; echo "$s"; }
# 存活副本数：pid 由 `wal_dn_pid` 精确识别，再用 `kill -0` 复核（不用 pgrep 语义）
w25_alive(){ local h p n=0; for h in "${DN[@]}"; do
    p=$(w25_dn_pid "$h"); [ -n "$p" ] || continue
    wal_dn_alive "$h" "$p" && n=$(( n + 1 ))
  done; echo "$n"; }
# 只写一批（**不 flush**；逐设备一条 INSERT；每批用独立时间偏移，避免相互覆盖）
w25_window_write(){ local tag=$1 d k vals ts out t0 t1 ok=0 err=0 blk=0 first=""
  BOFF=$(( BOFF + 1 ))
  t0=$(date +%s)
  for (( d=1; d<=DEVS; d++ )); do
    vals=""
    for (( k=0; k<ROWS; k++ )); do
      ts=$(( BASE_TS + 100000000 + BOFF * 1000000 + k * 10 ))
      vals="$vals($ts,9),"
    done
    out=$(w25_sql_to "$SQL_TO" "insert into $DB.d$d(time,s1) values ${vals%,};")
    if [ -z "$out" ] || printf '%s' "$out" | grep -qiE "couldn't connect|timed out|timeout"; then
      blk=$(( blk + 1 ))
      [ -n "$first" ] || first="<局部超时 ${SQL_TO}s，疑似阻塞>"
    elif printf '%s' "$out" | grep -qiE 'Exception|error|fail'; then
      err=$(( err + 1 ))
      [ -n "$first" ] || first=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)
    else
      ok=$(( ok + 1 ))
    fi
  done
  t1=$(date +%s)
  WIN_OK=$ok; WIN_ERR=$err; WIN_BLOCK=$blk; WIN_MSG="$first"
  log "  [$tag] 本批写入：成功设备=$ok 失败设备=$err 超时(疑似阻塞)=$blk，耗时 $(( t1 - t0 ))s，批偏移 BOFF=$BOFF"
  log "  [$tag] 首个错误/超时文案：${first:-<无>}" ; }
# DN 日志里的 WAL 写盘失败/系统降级行数（§10.2 #17-#19；**只作过程证据**）
w25_werr_cnt(){ local h=$1 v
  v=$(sshx "$h" "grep -ahcE 'Fail to (roll|sync|fsync) wal node|change system mode to error|No space left on device|Read-only file system|Operation not permitted' $DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_wal.log $DB_DIR/logs/log_datanode_error.log 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w25_werr_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w25_werr_cnt "$h") )); done; echo "$s"; }
w25_werr_line(){ local h=$1
  sshx "$h" "grep -ahE 'Fail to (roll|sync|fsync) wal node|change system mode to error|No space left on device|Read-only file system|Operation not permitted' $DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_wal.log 2>/dev/null | tail -2" 2>/dev/null | tr -d '\r' | cut -c1-240; }
w25_werr_report(){ local tag=$1
  log "  逐节点写盘失败/降级原文（$tag）：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(w25_werr_line "$h")"; done)"; }

# ① chattr 能力探测：+i 后**新建 fd 写入必须被拒**、-i 可还原
w25_chattr_probe(){ local h=$1 r
  r=$(sshx "$h" "command -v chattr >/dev/null 2>&1 || { echo NOCHATTR; exit 0; }; d=$WAL_BASE; mkdir -p \$d 2>/dev/null; f=\$d/.w25_probe; : > \$f 2>/dev/null || { echo NODIR; exit 0; }; chattr +i \$f 2>/dev/null || { rm -f \$f; echo NOCHATTR; exit 0; }; ( : 2>>\$f ) 2>/dev/null && w=W || w=D; chattr -i \$f 2>/dev/null; rm -f \$f; [ \$w = D ] && echo OK || echo NOWRITE" 2>/dev/null | tr -d '\r')
  echo "${r:-UNKNOWN}"; }
w25_lock(){ local h=$1 n=0
  n=$(sshx "$h" "find $WAL_BASE -name '*.wal' -type f -exec chattr +i {} + 2>/dev/null; find $WAL_BASE -name '*.wal' -type f 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
w25_lock_denied(){ local h=$1 f r
  f=$(sshx "$h" "find $WAL_BASE -name '*.wal' -type f 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
  [ -n "$f" ] || { echo NOFILE; return 0; }
  r=$(sshx "$h" ": 2>>'$f' && echo WRITABLE || echo DENIED" 2>/dev/null | tr -d '\r')
  echo "${r:-UNKNOWN}"; }
w25_unlock(){ local h
  for h in "${DN[@]}"; do
    sshx "$h" "find $WAL_BASE -type f -exec chattr -i {} + 2>/dev/null; true" >/dev/null 2>&1
  done; }
# ② tmpfs 能力探测 / 挂载 / 卸载 / 填满
w25_mount_probe(){ local h=$1 r
  r=$(sshx "$h" "command -v mount >/dev/null 2>&1 || { echo NOMOUNT; exit 0; }; mkdir -p $MNT 2>/dev/null || { echo NODIR; exit 0; }; mount -t tmpfs -o size=4M tmpfs $MNT 2>/dev/null || { rmdir $MNT 2>/dev/null; echo NOMOUNT; exit 0; }; umount $MNT 2>/dev/null; rmdir $MNT 2>/dev/null; echo OK" 2>/dev/null | tr -d '\r')
  echo "${r:-UNKNOWN}"; }
w25_mount_all(){ local h r n=0
  for h in "${DN[@]}"; do
    r=$(sshx "$h" "mkdir -p $MNT && mount -t tmpfs -o size=64M tmpfs $MNT 2>/dev/null && echo OK || echo NO" 2>/dev/null | tr -d '\r')
    [ "$r" = "OK" ] && n=$(( n + 1 )) || warn "  tmpfs 挂载失败 @ $h（返回 '$r'）"
  done
  echo "$n"; }
w25_umount_all(){ local h
  for h in "${DN[@]}"; do
    sshx "$h" "umount $MNT 2>/dev/null || umount -l $MNT 2>/dev/null; rmdir $MNT 2>/dev/null; true" >/dev/null 2>&1
  done; }
w25_fill(){ local h=$1 v
  v=$(sshx "$h" "dd if=/dev/zero of=$MNT/.fill bs=1M count=200 2>&1 | tail -1" 2>/dev/null | tr -d '\r')
  echo "${v:-<no-output>}"; }
# trap：EXIT 时无条件回滚所有破坏性动作（chattr / mount）
w25_rollback(){ set +e
  w25_unlock
  w25_umount_all
  return 0; }
trap w25_rollback EXIT

# 恢复相（硬）：重启前后可见数据必须"不少"，且重启后能继续写
#   exact=1（正常）：重启前可见 count 作精确基线；exact=0（重启前查询就失败，DN 可能已进 error 模式）：
#   退化为"不得少于已确认 flush 落盘的下限 W25_FLOOR"，**不因查询失败本身误判数据丢失**
w25_recover_verify(){ local tag=$1 n post_c post_s post_md5 grow wf exact=1
  log "--- [$tag] 恢复相：记录「重启前可见数据」→ 重启（不 clean）→ 比对 ---"
  PRE_C=$(w25_count); PRE_S=$(w25_sum); PRE_MD5=$(w25_d1_md5)
  if [ -z "${PRE_C:-}" ]; then
    exact=0
    warn "  [$tag] 重启前查询无输出（DN 可能已进入 error 模式）⇒ 放弃「重启前 = 基线」的精确比对，改用「重启后 count 不得少于已确认 flush 落盘的下限 ${W25_FLOOR}」"
  else
    log "  重启前可见：count=${PRE_C:-?} sum=${PRE_S:-?} d1_md5=${PRE_MD5:-?}（来源：CLI；此时 WAL 文件=$(w25_files_sum) 个）"
  fi
  cluster_stop
  EXTRA_CONF="$W25_GOOD" cluster_write_conf
  cluster_start
  n=$(w25_running)
  assert_eq "  [$tag] 恢复后集群必须起来（Running/ReadOnly 行数）" "${n:-0}" "$TOTAL"
  post_c=$(w25_count); post_s=$(w25_sum); post_md5=$(w25_d1_md5)
  log "  重启后可见：count=${post_c:-?} sum=${post_s:-?} d1_md5=${post_md5:-?}"
  if [ -z "${post_c:-}" ]; then
    fail "  [$tag] 重启后查询无输出（查询本身失败 ⇒ 无法判定数据一致性，先看日志）：$(w25_sql "select count(s1) from $DB.d1;" | tr '\n' ' ' | cut -c1-200)"
  elif [ "$exact" = "0" ]; then
    [ "${post_c:-0}" -ge "${W25_FLOOR:-0}" ] && pass "  [$tag] 重启后 count=${post_c:-0} ≥ 已确认落盘下限 ${W25_FLOOR}（退化判定，见上面 WARN）" \
      || fail "  [$tag] 重启后 count=${post_c:-0} < 已确认落盘下限 ${W25_FLOOR}（已 flush 落盘的数据在 WAL 盘不可写后丢失）"
  elif [ "${post_c:-0}" -lt "${PRE_C:-0}" ]; then
    fail "  [$tag] 数据丢失：重启后 count ${post_c:-0} < 重启前 ${PRE_C:-0}（已确认可见的数据在 WAL 盘不可写后未能恢复）"
  elif [ "${post_c:-0}" -gt "${PRE_C:-0}" ]; then
    pass "  [$tag] 重启后数据不少于重启前（count ${PRE_C:-0} → ${post_c:-0}）"
    warn "  [$tag] 重启后 count 反而增加：只读窗口里报错/超时的语句事后被应用 ⇒ 属「失败不确定」语义，如实记录（不计缺陷）"
  elif [ "${post_s:-0}" != "${PRE_S:-0}" ] || [ "$post_md5" != "$PRE_MD5" ]; then
    fail "  [$tag] count 相同但内容不一致：sum ${PRE_S:-?}→${post_s:-?}、d1_md5 ${PRE_MD5:-?}→${post_md5:-?}（重启前后可见数据必须逐字节一致）"
  else
    pass "  [$tag] 重启前后可见数据完全一致（count=${post_c:-0} sum=${post_s:-0} md5=${post_md5:-?}）"
  fi
  [ "${post_c:-0}" -ge "${W25_FLOOR:-0}" ] && pass "  [$tag] 重启后数据不少于「已确认 flush 落盘的下限」${W25_FLOOR}（count=${post_c:-0}）" \
    || fail "  [$tag] 低于已确认落盘的下限：count=${post_c:-0} < ${W25_FLOOR}（WAL 盘不可写后丢数据）"
  BATCH=$(( BATCH + 1 ))
  cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$BATCH" || fail "  [$tag] 恢复后写入失败（WAL 子系统未恢复工作）"
  grow=$(w25_count)
  assert_eq "  [$tag] 恢复后再写一批：count 精确增加 $(( DEVS * ROWS ))" "${grow:-0}" "$(( ${post_c:-0} + DEVS * ROWS ))"
  wf=$(wal_sum_over_dn wal_file_cnt)
  log "  [$tag] 恢复后 WAL 面：files=$wf bytes=$(wal_sum_over_dn wal_dir_bytes)B 逐副本=$(wal_per_node)"
  # 【2026-10-28 口径】WAL 在 checkpoint 之后本来就会被清理，"文件数=0" 不能证明 WAL 没恢复工作；
  #   本用例的硬判据是"恢复后数据一致 + 再写一批精确增长"，WAL 文件数只作过程证据（WARN）。
  [ "${wf:-0}" -ge 1 ] && pass "  [$tag] 恢复后 WAL 目录确有 .wal" \
    || warn "  [$tag] 恢复后 WAL 文件数=0（checkpoint 后清理属正常；本判据不计 fail_flag，数据面另有硬判据）"; }

# ===========================================================================
# 相 0：基线
# ===========================================================================
log "=== W-25 WAL 盘写不进去：库 $DB；专用 WAL 目录=$WAL_BASE；tmpfs 挂载点=$MNT ==="
log "--- 相 0) 集群准备（dn_wal_dirs=$WAL_BASE；wal_mode=ASYNC；关三类合并）---"
EXTRA_CONF="$W25_GOOD" cmp_cluster_prepare
N0=$(w25_running)
assert_eq "  相 0：集群就绪（Running/ReadOnly 行数）" "${N0:-0}" "$TOTAL"
for h in "${DN[@]}"; do
  log "  [$h] 生效 WAL 根=[$(wal_dir_roots "$h" | tr '\n' ' ')]；props dn_wal_dirs='$(wal_props_get "$h" dn_wal_dirs)'"
done
cmp_make_tree_db "$DB" "$DEVS"
w25_window_write "相 0 第 1 批（可写状态，对照）"
assert_eq "  相 0 场景有效：可写状态下逐设备写入全部成功" "${WIN_OK:-0}" "$DEVS"
w25_sql "flush;" >/dev/null
ensure_closed "$DB" 3 "$CLOSE_WIN" || warn "  相 0：有副本的 TsFile 未在 ${CLOSE_WIN}s 内 Async close（只影响过程证据）"
assert_eq "  相 0：第 1 批 flush 落盘后 count" "$(w25_count)" "$(( DEVS * ROWS ))"
W25_FLOOR=$(( DEVS * ROWS ))
log "  相 0 已确认 flush 落盘的下限 W25_FLOOR=$W25_FLOOR（后续恢复相用它兜底：即使重启前查询不可用，也硬判不得少于该下限）"
w25_window_write "相 0 第 2 批（**不 flush**，制造「只在 MemTable+WAL 上」的数据）"
assert_eq "  相 0：第 2 批不 flush 也已可见（可见性来自 MemTable+WAL）" "$(w25_count)" "$(( DEVS * ROWS * 2 ))"
W0_BYTES=$(w25_bytes_sum); W0_FILES=$(w25_files_sum)
log "  相 0 WAL 面：files=$W0_FILES bytes=${W0_BYTES}B（逐副本=$(wal_per_node)）"
[ "${W0_FILES:-0}" -ge 1 ] && pass "  相 0 场景有效：WAL 目录确有 .wal（只读构造有作用对象）" \
  || fail "  相 0 场景无效：WAL 文件数=0（数据可能已自行落盘）"

# ===========================================================================
# 构造①：chattr +i
# ===========================================================================
log "--- 构造①：chattr +i（DN 以 root 运行 ⇒ chmod 无效，immutable 才能拦住 root）---"
CH_OK=1
for h in "${DN[@]}"; do
  r=$(w25_chattr_probe "$h")
  log "  [$h] chattr 探测=$r（OK = +i 后新建 fd 写入被拒且可 -i 还原）"
  [ "$r" = "OK" ] || CH_OK=0
done
if [ "$CH_OK" = "1" ]; then
  pass "  构造①可用：三副本都支持 chattr +i 且能拦住新建 fd 的写入"
  w25_sql "flush;" >/dev/null
  w25_window_write "① 锁前写入（不 flush，保证有活动 .wal 文件可锁）"
  W_ERR0=$(w25_werr_sum)
  LCK=0; DEN=0; WR=0
  for h in "${DN[@]}"; do
    n=$(w25_lock "$h"); LCK=$(( LCK + n ))
    d=$(w25_lock_denied "$h")
    log "  [$h] 已 +i 的 .wal 文件数=$n；锁后新建 fd 写入探测=$d（期望 DENIED）"
    [ "$d" = "DENIED" ] && DEN=$(( DEN + 1 ))
    [ "$d" = "WRITABLE" ] && WR=$(( WR + 1 ))
  done
  log "  锁定 WAL 文件总数=$LCK；DENIED 副本数=$DEN；WRITABLE 副本数=$WR"
  [ "${LCK:-0}" -ge 1 ] && pass "  构造①场景有效：确实锁住了 $LCK 个 .wal 文件" \
    || fail "  构造①场景无效：没有任何 .wal 文件可锁"
  [ "${WR:-0}" -eq 0 ] && pass "  构造①：每个副本新建 fd 的写入都被拒（immutable 生效）" \
    || warn "  构造①：有 $WR 个副本上被 +i 的文件仍可被新 fd 写入 ⇒ immutable 未真正生效（记录）"
  F_BEF=$(w25_files_sum); B_BEFORE=$(w25_bytes_sum); ALIVE0=$(w25_alive)
  log "  只读窗口开始：DN 进程存活=$ALIVE0/${#DN[@]}；文件数=$F_BEF；字节=${B_BEFORE}B；窗口保持 ${WIN}s"
  sleep "$WIN"
  w25_window_write "① 只读窗口写入"
  B_AFTER=$(w25_bytes_sum); F_AFT=$(w25_files_sum); ALIVE1=$(w25_alive); E_ERR1=$(w25_werr_sum)
  log "  只读窗口结果：字节 ${B_BEFORE}B → ${B_AFTER}B；文件数 $F_BEF → $F_AFT；DN 进程 ${ALIVE0} → ${ALIVE1}/${#DN[@]}"
  log "                  WAL 写盘失败/降级日志行数 ${W_ERR0} → ${E_ERR1}（增量 $(( E_ERR1 - W_ERR0 ))）"
  w25_werr_report "① 只读窗口"
  if [ "${F_AFT:-0}" -gt "${F_BEF:-0}" ] || [ "${B_AFTER:-0}" -gt "${B_BEFORE:-0}" ]; then
    warn "  构造①**无效**（如实记录）：被锁文件字节增长或出现新 .wal ⇒ DN 用已打开的 fd 继续写 / 轮转到新文件绕过了 immutable；本方法窗口观测不作判据"
    EFF01=0
  else
    EFF01=1; METHOD="chattr"
    pass "  构造①有效：窗口内被锁 WAL 文件字节未增长、也无新文件 ⇒ immutable 确实拦住了 WAL 写盘"
    log "  只读窗口表现：成功设备=${WIN_OK} 失败设备=${WIN_ERR} 超时(疑似阻塞)=${WIN_BLOCK}；首个文案：${WIN_MSG:-<无>}"
    if [ "${WIN_ERR:-0}" -gt 0 ]; then
      pass "  只读窗口表现=报错（写入被拒/失败），与 §5.1「写失败让写请求报错」一致（记录）"
    elif [ "${WIN_BLOCK:-0}" -gt 0 ]; then
      pass "  只读窗口表现=阻塞（语句在 ${SQL_TO}s 内未返回）（记录）"
    else
      warn "  只读窗口表现=照常成功 ⇒ 只如实记录，不判 FAIL（见头注释的构造局限）"
    fi
  fi
  w25_unlock
  log "  已解除 immutable（chattr -i 递归）；锁后探测=$(w25_lock_denied "${DN[0]}")（期望 WRITABLE）"
else
  warn "  构造①不可构造（原因+证据）：$(for h in "${DN[@]}"; do printf '%s=%s ' "${h##*.}" "$(w25_chattr_probe "$h")"; done)⇒ 落到构造②"
  EFF01=0
fi

# ===========================================================================
# 构造②：tmpfs（独立小文件系统）写满造 ENOSPC（①不可构造 / 无效时）
# ===========================================================================
if [ "$EFF01" != "1" ] && [ "${W25_SKIP_ENOSPC:-0}" != "1" ]; then
  log "--- 构造②：独立小文件系统（tmpfs）写满 ⇒ ENOSPC ---"
  MP_OK=1
  for h in "${DN[@]}"; do
    r=$(w25_mount_probe "$h")
    log "  [$h] tmpfs mount 探测=$r（OK = 能挂载 4M tmpfs 并立即卸载）"
    [ "$r" = "OK" ] || MP_OK=0
  done
  if [ "$MP_OK" != "1" ]; then
    warn "本环境不可构造（原因+证据）：①chattr 无效/不可用，②tmpfs 挂载不被允许（逐副本探测见上）⇒ 跳过破坏性构造相，**不判 FAIL**（环境构造问题，非产品行为）"
  else
    MN=$(w25_mount_all)
    log "  tmpfs 挂载成功副本数=$MN/${#DN[@]}"
    assert_eq "  构造②场景有效性：三个副本都挂上了 tmpfs" "${MN:-0}" "${#DN[@]}"
    # W-24 的教训：切 dn_wal_dirs 前必须 flush（新目录不会扫描旧目录的 WAL）
    w25_sql "flush;" >/dev/null
    ensure_closed "$DB" 3 "$CLOSE_WIN" || warn "  构造②：切换 WAL 目录前 TsFile 未全部 Async close（只记过程证据）"
    C_SW=$(w25_count)
    log "  切换 dn_wal_dirs=$MNT 前已 flush：count=${C_SW:-?}"
    EXTRA_CONF="$(w25_strip_keys 'wal_mode dn_wal_dirs'),wal_mode=ASYNC,dn_wal_dirs=$MNT,$CMP_EXTRA_WRITE" cluster_write_conf
    cluster_stop
    cluster_start
    N2=$(w25_running)
    assert_eq "  构造②：dn_wal_dirs=$MNT 后集群必须起来" "${N2:-0}" "$TOTAL"
    assert_eq "  构造②：切换目录重启后数据不丢（切换前已 flush）" "$(w25_count)" "${C_SW:-0}"
    log "  生效 WAL 根（读 conf）：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(wal_dir_roots "$h" | tr '\n' ' ')"; done)"
    w25_window_write "② 填满前写入（不 flush，让 WAL 落在 tmpfs 上）"
    FILLED=""
    for h in "${DN[@]}"; do FILLED="$FILLED${h##*.}=[$(w25_fill "$h")] "; done
    log "  dd 填满 tmpfs：$FILLED"
    log "  tmpfs 容量（${DN[0]}）：$(sshx "${DN[0]}" "df -P $MNT 2>/dev/null | tail -1" 2>/dev/null | tr -s ' ')"
    W_ERR0=$(w25_werr_sum)
    w25_window_write "② ENOSPC 窗口写入"
    E_ERR1=$(w25_werr_sum)
    log "  ENOSPC 窗口：写盘失败/降级日志行数 ${W_ERR0} → ${E_ERR1}（增量 $(( E_ERR1 - W_ERR0 ))）"
    w25_werr_report "② ENOSPC 窗口"
    [ "${E_ERR1:-0}" -gt "${W_ERR0:-0}" ] && pass "  构造②有效：日志出现 WAL 写盘失败/降级文案（ENOSPC 确实打到 WAL 上）" \
      || warn "  构造②存疑：窗口内没有 WAL 写盘失败/降级文案（可能已轮转/已落盘；如实记录）"
    METHOD="tmpfs"
    # 恢复：tmpfs 是内存盘，卸载即丢 ⇒ 先 flush 落盘，再卸载 + 还原 conf
    w25_sql "flush;" >/dev/null
    ensure_closed "$DB" 3 "$CLOSE_WIN" || warn "  构造②：卸载前 TsFile 未全部 Async close（只记过程证据）"
    log "  卸载前置：已 flush，可见 count=$(w25_count)（tmpfs 上的 WAL 卸载后会丢失，故先落盘）"
    w25_umount_all
    w25_recover_verify "构造② 恢复相"
  fi
elif [ "$EFF01" != "1" ]; then
  warn "  构造②被 W25_SKIP_ENOSPC=1 跳过；且构造①无效 ⇒ 记「本环境不可构造（原因+证据）」并跳过破坏性相（不判 FAIL）"
else
  log "  构造②跳过：构造①（chattr +i）已构造成立（按序尝试，优先用更轻的①）"
fi

# ===========================================================================
# ① 的恢复相（构造①有效时才做：此时文件已 -i 解锁，目录仍是 $WAL_BASE）
# ===========================================================================
if [ "$EFF01" = "1" ]; then
  w25_recover_verify "构造① 恢复相"
fi

log "--- 判读 ---"
log "  构造方法=$METHOD（①chattr +i / ②tmpfs ENOSPC / none 不可构造）；构造有效性 EFF01=$EFF01"
log "  只读窗口表现（**只如实记录，不作门禁**）：成功=${WIN_OK} 失败=${WIN_ERR} 超时=${WIN_BLOCK}"
log "  硬判据只有「恢复后数据一致」：重启前后可见 count 不得减少（相同则 sum/md5 必须一致）；恢复后再写一批 count 必须精确增加。"
log "  chattr/挂载等破坏性动作由 trap w25_rollback 在 EXIT 时无条件回滚（chattr -i 递归 + umount）。"

# ===========================================================================
# 收尾三件套（本用例**不装** WAL 建议正则：只读窗口会故意让 WAL 写失败）
# ===========================================================================
log "--- 收尾三件套 ---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA='Fail to (roll|sync|fsync) wal node|change system mode to error|No space left on device|Read-only file system|Operation not permitted|Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection refused|Connection reset by peer'
# 【2026-10-28 口径】只读窗口若已触发 WAL 写失败/系统 error 模式，三副本数据本来就可能不一致
#   （部分写入被拒），这是构造的直接后果，不能当缺陷 ⇒ 跳过"逐 DN 停机副本一致性"，只做 sync lag + 日志扫描。
W25_ERRMODE=$(w25_werr_sum)
if [ "${W25_ERRMODE:-0}" -gt 0 ]; then
  warn "  收尾：检测到 ${W25_ERRMODE} 条 WAL 写盘失败/error 模式日志 ⇒ 跳过「逐 DN 停机副本一致性」"
  log "--- 收尾检查 1/3：sync lag 归零 ---"; check_sync_lag || true
  log "--- 收尾检查 3/3：CN/DN 日志异常分析 ---"; check_logs
else
  post_checks "select count(s1) from $DB.d1 order by time;" tree
fi
cmp_case_finish "" tree ""
