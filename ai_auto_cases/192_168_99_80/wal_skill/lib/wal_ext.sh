#!/bin/bash
# ============================================================================
# 存储模块 WAL（写前日志）专项 skill —— WAL 专属观测/操作层（可选层；**默认不改变任何行为**）
#
# 为什么需要这一层：`lib/cmp.sh` 的观测面全是"合并语义"（TsFile 计数、Compaction 日志、
# writeLock 卡死线程），WAL 用例要的是另一套：
#   · 目录面：WAL 目录（`wal_dirs` 默认 `data/wal`）下的 `_<version>.wal` / `_<version>.checkpoint`
#   · 文件面：WAL 文件总字节（压缩对照用）、文件尾魔数 `WAL-V2`（确认"这真是 WAL 文件"）
#   · 状态面：阻塞中的写入线程（阻写=阻塞而非报错）、DN 进程/堆内存
#   · 故障面：kill -9（模拟掉电）后重启并等重放
#   · 指标面：DN metrics 端口里 WAL 相关指标（文档未给指标名 ⇒ **动态发现**，缺了只 WARN）
#
# 依据：`docs/req_sources/design_extract.md`（目录/文件名/魔数/Type 字节）、
#       `docs/req_sources/feature_extract.md`（压缩/队列内存/OBJECT）、
#       `docs/req_sources/source_grounding.md`（源码 file:line 印证）
#
# ⚠️ 三条纪律：
#   ① 本层**不修改** `lib/common.sh` / `lib/cmp.sh` 的默认语义；不导出钩子时行为完全一致。
#   ② 钩子（`CMP_ERR_PAT_CUSTOM` / `CMP_POSITIVE_EVIDENCE_FN`）只在 `check_logs` **被调用时**读取，
#      设置动作必须放在 post_checks/check_logs 之前。
#   ③ 所有 ssh 命令都必须是**单行、无本地变量泄漏**的：`$DB_DIR` 是本机变量、要让它在本机展开；
#      远端要用的变量用 `\$` 转义（cmp.sh 的 `cmp_log_files` 就是踩过这个坑才写成函数的）。
# ============================================================================

# ---------------------------------------------------------------------------
# ① WAL 目录定位
#   优先级：配置文件里的 wal_dirs/dn_wal_dirs（本机读远端文件）→ 常见相对路径探测 → find 兜底。
#   返回：一行一个绝对路径（可能有多个，wal_dirs 支持逗号分隔的多目录）。
#   ⚠️ RC8 首轮踩过的坑（已修）：
#     a) find 兜底会命中**安装目录**里的同名目录（`<db>/tools/wal`、`<db>/tools/windows/wal`），
#        于是"按库统计"恒为 0 而且**没有任何 WARN**（W-24 观察到此现象）⇒ 兜底时排除
#        `/tools/`、`/windows/`，并且**退化到兜底/结果为空都要 WARN**（不许静默）。
#     b) 本函数在一条用例里会被调用几十次（每次采样都调），WARN 只报一次/每节点，避免刷爆
#        v_warnMessage。
# ---------------------------------------------------------------------------
# 私有：可能没有 $OUT（被其它脚本 source 时）也能安全 WARN
_wal_warn(){ if [ -n "${OUT:-}" ]; then warn "$*"; else printf 'WARN %s\n' "$*" >&2; fi; }
_wal_warn_once(){ local h=$1; shift
  case " ${WAL_DIR_WARNED:-} " in *" $h "*) return 0 ;; esac
  WAL_DIR_WARNED="${WAL_DIR_WARNED:-}$h "; _wal_warn "$*"; }
wal_dir_roots(){ local h=$1 v out="" src=conf
  # 配置键在不同版本可能是 wal_dirs（1.x/2.0 设计文档）或 dn_wal_dirs（2.0 新版模板）
  # 【2026-10-28】必须**优先 dn_wal_dirs**：模板里同时存在旧键 wal_dirs，一起 grep 再 tail -1 会取到旧键的默认值
  #   （实测 properties 里 dn_wal_dirs 是自定义值、文件 md5 也没变，但本函数读成了默认目录 ⇒ W-24 假 FAIL）。
  v=$(sshx "$h" "grep -hE '^[[:space:]]*dn_wal_dirs[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
  [ -z "$v" ] && v=$(sshx "$h" "grep -hE '^[[:space:]]*wal_dirs[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
  [ -n "$v" ] && out=$(printf '%s' "$v" | tr ',' '\n' | sed 's/[[:space:]]//g' | while read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        /*) echo "$p" ;;
        *)  echo "$DB_DIR/$p" ;;
      esac
    done)
  # 探测常见路径（设计文档给的是 data/wal；2.0 也有 data/datanode/wal 的布局）
  if [ -z "$out" ]; then
    src=probe
    out=$(sshx "$h" "for p in $DB_DIR/data/wal $DB_DIR/data/datanode/wal $DB_DIR/wal; do [ -d \"\$p\" ] && echo \"\$p\"; done" 2>/dev/null | tr -d '\r')
  fi
  # 兜底：find（限深，避免扫全盘）。**必须排除安装目录里的 tools/**、tools/windows/**
  if [ -z "$out" ]; then
    src=find
    out=$(sshx "$h" "find $DB_DIR -maxdepth 4 -type d -name wal 2>/dev/null | grep -vE '/(tools|windows)/' | head -3" 2>/dev/null | tr -d '\r')
    [ -n "$out" ] && _wal_warn_once "$h" "  [$h] wal_dir_roots 退化到 find 兜底（命中：$(printf '%s' "$out" | tr '\n' ' ')）——请核对 dn_wal_dirs 是否写对；按库统计可能因此恒为 0"
  fi
  if [ -z "$out" ]; then
    _wal_warn_once "$h" "  [$h] wal_dir_roots 没能定位到任何 WAL 目录（conf 键为空、常见路径与 find 兜底都没命中）——后续 WAL 文件面统计会恒为 0，请检查 dn_wal_dirs/数据目录"
  fi
  printf '%s\n' "$out" | sed '/^$/d' | sort -u; }

# 把多目录展开成远端 find 的表达式（`dir1 dir2` → `dir1 dir2`）
wal_roots_arg(){ local h=$1 r; r=$(wal_dir_roots "$h" | tr '\n' ' '); printf '%s' "${r:-$DB_DIR/data/wal}"; }

# WAL 文件数（`*.wal`；可给第 2 个参数：region 过滤，例如 `root.walx-3` 的 `-3` 不参与文件名 ⇒ 用目录过滤）
wal_file_cnt(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# checkpoint 文件数
wal_ckpt_cnt(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.checkpoint' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# WAL 总字节（压缩对照的核心观测）
wal_dir_bytes(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# WALNode 子目录数（max_wal_nodes_num 用例）
wal_node_dirs(){ local h=$1 v
  v=$(sshx "$h" "find $(wal_roots_arg "$h") -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 文件清单（证据；含大小与相对路径）
wal_ls(){ local h=$1
  sshx "$h" "find $(wal_roots_arg "$h") \\( -name '*.wal' -o -name '*.checkpoint' \\) -printf '%s %p\n' 2>/dev/null | sort -k2 | head -40" 2>/dev/null | tr -d '\r'; }
# 文件尾魔数 `WAL-V2` 命中文件数（确认"这些确实是 WAL 文件"；二进制文件用 -a）
wal_magic_cnt(){ local h=$1 v
  v=$(sshx "$h" "for f in \$(find $(wal_roots_arg "$h") -name '*.wal' 2>/dev/null); do grep -qa 'WAL-V2' \"\$f\" && echo \"\$f\"; done | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 全集群口径（跨 DN 求和）
wal_sum_over_dn(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h"))); done; echo "$s"; }
# 逐副本证据串：`77=files/bytes 78=… 79=…`
wal_per_node(){ local h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(wal_file_cnt "$h")f/$(wal_dir_bytes "$h")B "; done; echo "$out"; }

# ---------------------------------------------------------------------------
# ② WAL 日志（文档未给日志关键字 ⇒ 只能按**源码文案**匹配；见 source_grounding.md）
# ---------------------------------------------------------------------------
# 日志文件列表。**必须用函数**（写成单引号变量时 $DB_DIR 不会展开 ⇒ 匹配恒为 0，本项目踩过）
wal_log_files(){ echo "$DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_wal.log"; }
# 跨 DN 日志行数求和（正证据/计数断言复用）
wal_log_sum(){ local pat=$1 h files n s=0
  for h in "${DN[@]}"; do
    files=$(sshx "$h" "ls $(wal_log_files) 2>/dev/null" 2>/dev/null | tr '\n' ' ')
    [ -n "$files" ] || continue
    n=$(sshx "$h" "grep -ahE '$pat' $files 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "${s:-0}"; }
# 日志尾部（证据）
wal_log_tail(){ local h=$1 n=${2:-8}
  sshx "$h" "grep -ahEi 'wal' \$(ls $(wal_log_files) 2>/dev/null) 2>/dev/null | tail -$n" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------------------
# ③ WAL 专属异常正则（**建议集**；每条都在源码里核对过出处后填写）
#   默认**不安装**：WAL 用例的负向相（非法配置、DISABLE 被拒、盘只读）会故意报错，
#   广谱正则会把预期失败误判成产品问题。
# ---------------------------------------------------------------------------
WAL_ERR_PAT_SUGGESTED='WAL[^|]*(failed|Failed to)|Failed to (write|append|fsync|recover|replay|read|delete) WAL|WALEntry[^|]*(failed|corrupt)|corrupt[^|]*WAL|WAL file[^|]*(corrupt|broken)|Failed to recover from WAL'
wal_err_pat_extra(){ printf '%s' "$WAL_ERR_PAT_SUGGESTED"; }
wal_install_err_pat(){ local extra=${1:-$WAL_ERR_PAT_SUGGESTED}
  if [ -z "$extra" ]; then warn "  wal_install_err_pat：正则为空 ⇒ 不安装（保持默认行为）"; return 0; fi
  if [ -n "${CMP_ERR_PAT_CUSTOM:-}" ]; then CMP_ERR_PAT_CUSTOM="$CMP_ERR_PAT_CUSTOM|$extra"
  else CMP_ERR_PAT_CUSTOM="$extra"; fi
  export CMP_ERR_PAT_CUSTOM
  log "  已安装 WAL 专属异常正则：$CMP_ERR_PAT_CUSTOM"; }

# ---------------------------------------------------------------------------
# ④ WAL 版"正证据"（export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence）
#   与合并 skill 的 starts/finishes 对应，WAL 关心：
#     ① WAL entry 落盘/刷盘相关行数   ② 恢复/重放相关行数   ③ WAL 文件删除/检查点相关行数
#     ④ WAL 目录文件数与总字节（文件面）
#   ⚠ 文档未给日志关键字 ⇒ 这里的计数是**弱证据**，只用于"确认 WAL 子系统确实在动"，
#     绝不作为功能判据（功能判据一律是数据面）。
# ---------------------------------------------------------------------------
wal_positive_evidence(){ local db="${WAL_EVIDENCE_DB:-}" w r c n
  w=$(wal_log_sum 'WAL|wal')
  r=$(wal_log_sum 'recover|Recover|replay|Replay')
  c=$(wal_log_sum 'WAL.*(delet|Delet|remov|Remov)|checkpoint|Checkpoint')
  n=$(wal_sum_over_dn wal_file_cnt)
  log "  WAL 正证据（全部 DN 日志累计）：含 wal 字样=${w:-0} 恢复/重放相关=${r:-0} 删除/检查点相关=${c:-0}"
  log "  WAL 正证据（文件面）：跨 DN WAL 文件数=${n:-0} 总字节=$(wal_sum_over_dn wal_dir_bytes)B；逐副本：$(wal_per_node)"
  [ -n "$db" ] && log "  （本用例库 $db；文件面按 WAL 目录统计，不按库过滤——WALNode 与 DataRegion 的映射见 design_extract.md §2）"
  return 0; }

# 包装：装上 WAL 正证据后调用 check_logs
wal_check_logs(){ local extra=${1:-} prev="${CMP_POSITIVE_EVIDENCE_FN:-}"
  CMP_POSITIVE_EVIDENCE_FN="${CMP_POSITIVE_EVIDENCE_FN:-wal_positive_evidence}"
  check_logs "$extra"
  CMP_POSITIVE_EVIDENCE_FN="$prev"; }

# ---------------------------------------------------------------------------
# ⑤ 故障注入：kill -9（掉电）/ 优雅停 / 单 DN 重启
# ---------------------------------------------------------------------------
# **精确取 DataNode 的 JVM pid**（本层唯一取 pid 的入口；用例里的 `*_dn_pid()` 也应改调它）
#   为什么不能用 `pgrep -f com.timecho.iotdb.DataNode`（RC8 首轮的根因）：
#     `sshx "$h" "pgrep -f com.timecho.iotdb.DataNode | head -1"` 这条命令在远端是以
#     `bash -c '<整串>'` 执行的，**这层 shell 自己的命令行里就含有 `com.timecho.iotdb.DataNode`**；
#     pgrep 只排除它自己、不排除父 shell ⇒
#       ① 取 pid 时可能拿到那层 shell（于是 `kill -9` 杀的是 shell，DataNode 毫发无损）；
#       ② **即使 DataNode 真的死了**，"是否已退出"的判断照样非空 ⇒ 表现为
#          "等满 180s 仍未退出 / kill -9 未生效"（W-04/W-05/W-12/W-19/W-26 实测都撞上）。
#   这里扫 `/proc/*/cmdline`，只认**可执行文件是 java**（`${c%% *}` 以 java 结尾）且命令行含
#   `DataNode` 的进程 ⇒ 天然排除 bash/sh/grep/pgrep/启动脚本；找不到就输出空（调用方据此判"没有 DN"）。
#   已核对本版本：`sbin/start-datanode.sh` 的主类是 `com.timecho.iotdb.DataNode`。
wal_dn_pid(){ local h=$1
  sshx "$h" 'for p in /proc/[0-9]*; do
      [ -r "$p/cmdline" ] || continue
      c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
      x=${c%% *}
      case "$x" in *java) ;; *) continue ;; esac
      case "$c" in *DataNode*) echo "${p#/proc/}"; break ;; esac
    done' 2>/dev/null | tr -d '\r' | head -1; }
# 某 DN 上 DataNode 是否还活着（0=活着 / 1=没有）：用 `kill -0` 复核真实 pid，不用 pgrep
wal_dn_alive(){ local h=$1 pid=$2
  [ -n "${pid:-}" ] || return 1
  sshx "$h" "kill -0 $pid" >/dev/null 2>&1; }
# 单 DN kill -9：模拟掉电（SIGKILL 不给 JVM 任何收尾机会；进程直接消失）
wal_kill9_dn(){ local h=$1 pid dl
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { warn "  $h 上没有 DataNode 进程（kill -9 跳过）"; return 1; }
  log "  kill -9 DataNode pid=$pid @ $h（模拟掉电；pid 由 /proc/*/cmdline 精确识别）"
  sshx "$h" "kill -9 $pid" || warn "  kill -9 $h 失败"
  # SIGKILL 正常 1~2s 就消失 ⇒ 只等 30s；超时**不死等**，打证据后返回失败
  dl=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < dl )); do
    wal_dn_alive "$h" "$pid" || { log "  $h DataNode pid=$pid 已退出（kill -0 复核）"; return 0; }
    sleep 2
  done
  warn "  $h DataNode pid=$pid 在 30s 内仍存活（SIGKILL 未生效？）；证据：$(sshx "$h" "ps -o pid,ppid,stat,args -p $pid 2>/dev/null | tail -1" 2>/dev/null | tr -d '\r' | cut -c1-300)"
  return 1; }
# 单 DN 优雅停（正常 stop 脚本；用于"节点下线"类场景）
wal_stop_dn(){ local h=$1 pid dl
  pid=$(wal_dn_pid "$h")
  log "  优雅停止 DataNode @ $h（pid=${pid:-<未找到>}）"
  sshx "$h" "bash $DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true" || warn "  stop-datanode 非 0"
  dl=$(( $(date +%s) + ${DN_DOWN_WAIT_SEC:-180} ))
  while (( $(date +%s) < dl )); do
    wal_dn_alive "$h" "$pid" || { log "  $h DataNode 已停止（kill -0 复核）"; return 0; }
    sleep 2
  done
  warn "  $h DataNode 未在 ${DN_DOWN_WAIT_SEC}s 内停止（pid=${pid:-?}）；证据：$(sshx "$h" "ps -o pid,ppid,stat,args -p ${pid:-0} 2>/dev/null | tail -1" 2>/dev/null | tr -d '\r' | cut -c1-300)"
  return 1; }
# 单 DN 启动（不动其它节点）
wal_start_dn(){ local h=$1
  log "  启动 DataNode @ $h"
  sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "  启动 $h 失败"
  local dl=$(( $(date +%s) + ${DN_RECOVER_WAIT_SEC:-300} )) st=""
  while (( $(date +%s) < dl )); do
    st=$(dn_state "$h")
    [ "$st" = "Running" ] && { log "  $h DataNode=${st}"; return 0; }
    sleep 5
  done
  warn "  $h DataNode 未在 ${DN_RECOVER_WAIT_SEC}s 内 Running（当前 '$st'）"; return 1; }
# 全集群重启（stop → start → ready）
wal_restart_all(){ cluster_stop; cluster_start; }

# ---------------------------------------------------------------------------
# ⑥ 恢复等待：重启后数据可见（WAL 重放完成）
#   `wait_scalar_tree`/`wait_scalar_table` 已经在 lib 里（轮询到值稳定），这里加一层
#   "WAL 文件被消费"的弱观测，便于打印证据。
# ---------------------------------------------------------------------------
wal_wait_replay(){ local db=$1 win=${2:-${WAL_REPLAY_WIN_SEC:-300}} dl h before after
  before=$(wal_sum_over_dn wal_file_cnt)
  log "  等待 WAL 重放（窗口 ${win}s；重启前 WAL 文件数=$before）"
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    sleep 10
    after=$(wal_sum_over_dn wal_file_cnt)
    if [ "${after:-0}" -lt "${before:-0}" ]; then
      log "  WAL 文件数下降：$before → $after（重放已消费部分 WAL）"; return 0
    fi
  done
  log "  WAL 文件数未下降（$before → ${after:-0}）——恢复后可能已重刷盘（见 design_extract.md §4：恢复后直接刷盘）"
  return 0; }

# ---------------------------------------------------------------------------
# ⑦ 指标面：文档未给 WAL 指标名 ⇒ 动态发现（缺了只 WARN）
# ---------------------------------------------------------------------------
# 列出该 DN metrics 里名字含 wal 的指标（时间序列名，去掉标签）
wal_metric_names(){ local h=$1
  sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -iE '^[a-zA-Z_:]*wal' | sed 's/[ {].*//' | sort -u" 2>/dev/null | tr -d '\r'; }
# 取某指标当前值之和（多标签时求和）；不存在时输出空
wal_metric(){ local h=$1 name=$2
  local pat
  pat=$(printf '%s' "$name" | sed 's/\./\\./g')
  sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pat(\\{| )' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-'; }
# 概率性指标抓取（写入前后对比方向）
wal_metric_snapshot(){ local h=$1 names; names=$(wal_metric_names "$h" | tr '\n' ' ')
  printf '%s' "$names"; }

# ---------------------------------------------------------------------------
# ⑧ 配置面：热加载 vs restart-only
#   `cmp_eff <h> <key>`（table 方言 show configuration）读**运行期生效值**；
#   `wal_props_get` 读**配置文件里的值**（判断"已落盘但未生效"）。
# ---------------------------------------------------------------------------
wal_props_get(){ local h=$1 k=$2
  sshx "$h" "grep -hE '^[[:space:]]*$k[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r'; }
wal_eff(){ local h=$1 k=$2; cmp_eff "$h" "$k"; }
wal_eff_all(){ local h=$1 k=$2; cmp_eff_all "$h" "$k"; }
# SET CONFIGURATION（返回文案是判据的一部分）
wal_set(){ local k=$1 v=$2; cmp_set_hot "$k" "$v"; }

# ---------------------------------------------------------------------------
# ⑨ 阻写观测：阻塞中的写入线程数（阻写=阻塞写入线程，非报错；见 feature_extract.md B）
#   ⚠️ pid 一律用 `wal_dn_pid`：旧的 `pgrep -f com.timecho.iotdb.DataNode` 会拿到远端
#      `bash -c` 包装 shell 的 pid ⇒ `jstack` 打空 ⇒ 阻塞线程数恒 0（假阴性）。
# ---------------------------------------------------------------------------
wal_blocked_writers(){ local h=$1 pid v
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo 0; return; }
  v=$(sshx "$h" "jstack $pid 2>/dev/null | grep -cE 'MemoryControlledWALEntryQueue|nonFullCondition|WALEntryQueue'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# DN 堆使用率（WAL 队列内存用例；只作证据）
wal_heap_ratio(){ local h=$1 pid v
  pid=$(wal_dn_pid "$h")
  [ -n "${pid:-}" ] || { echo ""; return; }
  sshx "$h" "jcmd $pid GC.heap_info 2>/dev/null | grep -oE 'used [0-9]+K' | head -1" 2>/dev/null | tr -dc '0-9'; }
# OOM 相关日志行数（硬判据：必须为 0）
wal_oom_cnt(){ wal_log_sum 'OutOfMemoryError|java\.lang\.OutOfMemory|GC overhead limit exceeded'; }

# ---------------------------------------------------------------------------
# ⑩ OBJECT 目录（表模型 OBJECT 真实内容；WAL 中只存引用）
#   路径：`${data_dir}/object_data/<dataRegionId>/${B32(table)}/…/<timestamp>.bin`
# ---------------------------------------------------------------------------
wal_object_root(){ local h=$1
  sshx "$h" "for p in $DB_DIR/data/datanode/object_data $DB_DIR/data/object_data $DB_DIR/object_data; do [ -d \"\$p\" ] && echo \"\$p\"; done" 2>/dev/null | tr -d '\r' | head -1; }
wal_object_cnt(){ local h=$1 r; r=$(wal_object_root "$h"); [ -n "$r" ] || { echo 0; return; }
  sshx "$h" "find $r -name '*.bin' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'; }

# ---------------------------------------------------------------------------
# ⑪ **权威指标口径**（源码印证：`commons/service/metric/enums/Metric.java:80-85,156-157`；
#    详见 docs/req_sources/source_grounding.md §9）
#   这些指标比"扫目录/数日志"权威得多，**优先用它做过程证据**：
#     file_count{name="wal"}            → WAL 文件数
#     file_size{name="wal"}             → WAL 总字节
#     wal_queue_mem_cost{name="wal_queue_current_mem_cost"|"wal_queue_max_mem_cost"}
#                                       → WAL 队列内存（对应用户可见的"WAL 队列内存"上限/当前值）
#     wal_buffer{name="used_ratio"|"entries_count"|"wal_entry_num_for_one_tsfile"|
#                     "serialized_wal_buffer_size"|"wrote_wal_buffer_size"|
#                     "wal_compress_cost"|"wal_uncompress_cost"|
#                     "read_wal_buffer_size"|"read_wal_buffer_cost"|"write_wal_buffer_cost"}
#     wal_cost{stage="make_checkpoint"|"serialize_wal_entry"|"sync_wal_buffer"}
#     wal_node_num（tag name=wal_nodes_num）
#     wal_node_info{name="effective_ratio_info"|"oldest_mem_table_ram_when_cause_snapshot"|
#                        "oldest_mem_table_ram_when_cause_flush", type=<walNodeId>}
#     flush_memtable_count{type="wal_flush_memtable_count"}
#   ⚠️ 注意：`WALNode.java` 里"删除过期 WAL 条数"的结论文案是 **DEBUG 级**、
#      默认 logback `<root level="info">` 不落盘 ⇒ **不要拿日志文案当判据**，用上面的指标 + 目录文件数。
# ---------------------------------------------------------------------------
# 通用：按"指标名前缀 + 标签子串"求和的取值器
wal_metric_sum(){ local h=$1 pre=$2 tag=${3:-} v
  if [ -n "$tag" ]; then
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pre\\{' | grep -F '$tag' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
  else
    v=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -E '^$pre(\\{| )' | awk '{s+=\$NF} END{print s+0}'" 2>/dev/null | tr -dc '0-9.\-')
  fi
  echo "${v:-0}"; }
wal_metric_exists(){ local h=$1 pre=$2 n
  n=$(sshx "$h" "curl -s -m 8 http://$h:$DN_METRIC_PORT/metrics 2>/dev/null | grep -cE '^$pre(\\{| )'" 2>/dev/null | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && echo 1 || echo 0; }
# WAL 文件数 / 总字节（指标口径）
wal_metric_file_cnt(){ wal_metric_sum "$1" 'file_count' 'name="wal"'; }
wal_metric_file_bytes(){ wal_metric_sum "$1" 'file_size' 'name="wal"'; }
# 队列内存（当前 / 峰值）
wal_metric_queue_cur(){ wal_metric_sum "$1" 'wal_queue_mem_cost' 'wal_queue_current_mem_cost'; }
wal_metric_queue_max(){ wal_metric_sum "$1" 'wal_queue_mem_cost' 'wal_queue_max_mem_cost'; }
# WALBuffer 子指标（如 used_ratio / entries_count / wal_compress_cost）
wal_metric_buffer(){ wal_metric_sum "$1" 'wal_buffer' "name=\"$2\""; }
# WALNode 数量 / 快照与 flush 触发原因
wal_metric_node_num(){ wal_metric_sum "$1" 'wal_node_num'; }
wal_metric_snapshot_ram(){ wal_metric_sum "$1" 'wal_node_info' 'oldest_mem_table_ram_when_cause_snapshot'; }
wal_metric_flush_ram(){ wal_metric_sum "$1" 'wal_node_info' 'oldest_mem_table_ram_when_cause_flush'; }
wal_metric_eff_ratio(){ wal_metric_sum "$1" 'wal_node_info' 'effective_ratio_info'; }
wal_metric_flush_memtable_cnt(){ wal_metric_sum "$1" 'flush_memtable_count' 'wal_flush_memtable_count'; }
# 跨 DN 求和/逐副本证据（指标口径，优先用于压缩对照与清理对照）
wal_metric_sum_over_dn(){ local f=$1 h s=0; for h in "${DN[@]}"; do s=$((s + $($f "$h"))); done; echo "$s"; }
wal_metric_per_node(){ local f=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h") "; done; echo "$out"; }
# 一条命令打印全部关键指标（首轮采样/证据用）
wal_metrics_dump(){ local h=$1
  log "  [$h] WAL 指标：files=$(wal_metric_file_cnt "$h") bytes=$(wal_metric_file_bytes "$h") queue_cur=$(wal_metric_queue_cur "$h") queue_max=$(wal_metric_queue_max "$h") nodes=$(wal_metric_node_num "$h") eff_ratio=$(wal_metric_eff_ratio "$h")"; }

# ===========================================================================
# ⑫ **覆写 `row_sum`（CLI 聚合值的数值解析）** —— RC8 首轮 ≥8 条用例被误判的根因
#
#   被覆写的原实现：`lib/common.sh:171`
#     row_sum(){ ... | awk -F'|' '{s=0; for(i=2;i<NF;i++){v=$i; gsub(/[^0-9-]/,"",v); if(v!="")s+=v} print s}' }
#   它把每个单元格**按字符剥掉非数字**再累加；而 CLI 把 `sum()`/`min()`/`max()` 结果按 **double**
#   打印（`count()` 是 long，所以 count 一直是对的）⇒ 两种失败形态（同一根因）：
#     ① 值 < 1e7：`Double.toString` 打 `8016000.0` ⇒ 剥掉小数点得 `80160000` —— **×10**
#        （W-11 `实际=801600000 / 期望=80160000`；W-16 `804000/80400`；W-17、W-18、W-21、W-23 同）
#     ② 值 ≥ 1e7：`Double.toString` 改用科学计数法 `2.4018E7`（= 每设备 24,018,000）
#        ⇒ 剥成 `24018` + 指数 `7` = `240187` —— **÷100**，方向相反
#        （W-14 `实际=2401870 / 期望=240180000`；W-15 的 `1.604E7→16047`、`1.60613E7→1606137` 同）
#
#   ⇒ 结论（手算逐条核对过）：**离线核算的期望值公式全部正确，错的是"实际值"的解析**。
#     例：W-11 `DEVS=10, ROWS=2000, BATCHES=4`，值 = `k+b` ⇒ 每设备
#         `4*2000*1999/2 + 2000*4*5/2 = 7,996,000+20,000 = 8,016,000`，×10 设备 = 80,160,000 ✓期望；
#         实际日志 801,600,000 = `8,016,000×10`（每列 `8016000.0`→`80160000`）×10 列 ⇒ 解析放大 10 倍。
#     例：W-14 `10×4000×3`，值 = `k+b` ⇒ 每设备 24,018,000，×10 = 240,180,000 ✓期望；
#         实际 2,401,870 = `2.4018E7`→`240187` ×10 列 ⇒ 解析缩小约 100 倍。
#
#   为什么在**本层**覆写（而不是改 lib/common.sh）：`lib/common.sh` 是所有 skill 共用的基线，
#   本专项约定不改它；而 27 条用例的 source 顺序恒为 `common.sh → cmp.sh → wal_ext.sh`
#   （已逐条核对）⇒ 这里后定义者胜，运行期对**用例自身**与 `lib/cmp.sh` 的
#   `cmp_fp_tree`/`cmp_fingerprint` 一并生效（它们也调 row_sum，指纹必须与期望值同口径）。
#
#   语义与原实现保持一致：只取**第一条数据行**、逐列求和、输出整数字符串
#   （整数用 `%.0f`，非整数用 `%.6f`）；差别只在"怎么把一个单元格读成数"。
#   ⚠️ 同类坑本项目已记录过：`diskusage_skill/SKILL.md:60`「表模型聚合列是 double（`1698.0`）
#      ⇒ 数值解析必须用 awk 的 `+0`，不要用 gsub 去非数字字符（会放大 10 倍）」。
# ===========================================================================
row_sum(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '
  {
    s = 0
    for (i = 2; i < NF; i++) {
      v = $i
      gsub(/^[ \t\r]+/, "", v); gsub(/[ \t\r]+$/, "", v)
      # 只认真正的数值字面量（整数 / 小数 / 科学计数法 / 带符号）；null、空串、表头文本一律跳过
      if (v !~ /^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/) continue
      s += v + 0
    }
    if (s == int(s)) printf "%.0f\n", s
    else             printf "%.6f\n", s
  }'; }

# row_sum 单位自测（**离线**：只喂合成的 CLI 片段，不连集群、不读写任何文件）
#   用法： . lib/common.sh; . lib/cmp.sh; . lib/wal_ext.sh; wal_row_sum_selftest
#   ⚠️ 输入必须是**CLI 的真实表形态**：第 1 行是以 `|` 开头的表头（`table_rows` 会丢掉首行），
#      第 2 行才是数据行。聚合结果**没有 Time 列**（现场实测：`|count(root.dtd.m1.s1)|` + `|    2|`）。
_wal_rs_chk(){ local label=$1 input=$2 want=$3 got
  got=$(row_sum "$input")
  if [ "$got" = "$want" ]; then printf '  [ok] %s => %s\n' "$label" "${got:-<空>}"; return 0; fi
  printf '  [FAIL] %s => 实际[%s] 期望[%s]\n' "$label" "${got:-<空>}" "${want:-<空>}"; return 1; }
wal_row_sum_selftest(){ local bad=0 ten10 tenE7
  ten10='|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|8016000.0|'
  tenE7='|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|2.4018E7|'
  # ① count（long，无小数位）
  _wal_rs_chk 'count 单列（long）'          $'|count(root.x.d1)|\n|    2|'          '2'         || bad=$((bad+1))
  # ② sum < 1e7 的 double 形态（`8016000.0`）：原实现会给出 80160000（×10）
  _wal_rs_chk 'sum 单列（.0 形态）'         $'|sum(root.x.d1)|\n|8016000.0|'       '8016000'   || bad=$((bad+1))
  # ③ `sum(db.**)` 的真实形态：10 个序列 = 10 列
  _wal_rs_chk 'sum 十列（.0 形态）'         "|sum(**)|
$ten10"                                                                            '80160000'  || bad=$((bad+1))
  # ④ ≥1e7 时 Java 用科学计数法（`2.4018E7` = 24,018,000）：原实现会给出 240187（÷100）
  _wal_rs_chk 'sum 单列（E7 形态）'         $'|sum(root.x.d1)|\n|2.4018E7|'        '24018000'  || bad=$((bad+1))
  _wal_rs_chk 'sum 十列（E7 形态）'         "|sum(**)|
$tenE7"                                                                            '240180000' || bad=$((bad+1))
  # ⑤ 小值 / 负数 / null / 空集 / CRLF
  _wal_rs_chk 'min（1.0）'                  $'|min(root.x.d1)|\n|1.0|'              '1'         || bad=$((bad+1))
  _wal_rs_chk '负数（-1234.0）'             $'|min(root.x.d1)|\n|-1234.0|'          '-1234'     || bad=$((bad+1))
  _wal_rs_chk 'null 单元格跳过'             $'|sum(**)|\n|null|300.0|'               '300'       || bad=$((bad+1))
  _wal_rs_chk 'CRLF 行尾（ssh 带回车）'     "|sum(root.x.d1)|
|300.0|"$'\r'                                                                      '300'       || bad=$((bad+1))
  _wal_rs_chk '空集（调用方用 ${got:-0}）'  'Empty set.'                              ''          || bad=$((bad+1))
  if [ "$bad" = 0 ]; then printf '[ok] row_sum 自测全部通过（10 项）\n'; return 0; fi
  printf '[FAIL] row_sum 自测失败 %s 项\n' "$bad"; return 1; }

# ===========================================================================
# ⑬ **树方言聚合取值 + 序列指纹**（W-04/W-05/W-11/W-12 的指纹共用）
#
#   为什么需要这一层 —— 本版本（RC8 `v20121rc8_1016_ebaf9da`）**原始报错行**（99.80 上
#   `results/wal_compress_recovery_IoTConsensus_20261017_151032.out:226-237`、
#   `results/wal_recovery_flush_boundary_IoTConsensus_20261017_140840.out:320-327`）：
#     ① `select min(s1) from root.walcmp9.**`  ⇒ 701
#        `Error occurred during inferring UDF data type:`
#        同一形态在**设备路径**上也报（`select min(s1) from root.walcmp.d6`）
#        ⇒ 本版本的 `min`/`max` **不是内建聚合名**（被当 UDF ⇒ 类型推断失败）；
#        内建名是 `min_value`/`max_value`（服务端 jar 里聚合清单的正字面量：
#        `\b(count|sum|avg|extreme|max_value|min_value|first_value|last_value|max_time|min_time|…)\b\s*\(`
#        —— 其中**没有**裸 `min`/`max`）。指纹里因此曾经出现 `total_min_sum=ERR`。
#     ② `select count(s1), sum(s1), min(s1), max(s1) from <路径>` ⇒ 701
#        `Raw data and aggregation hybrid query is not supported`
#        （一条查询里混多个聚合；通配路径与设备路径**都**报）
#        ⇒ 而旧代码把它当成"报错才拆分"的兜底，CLI 的错误文本又不含 `Exception`（含 `Msg:`），
#          于是落到 else 分支、`table_rows` 取不到行 ⇒ **静默**打印 `dev_dN=count= sum= min= max=`。
#     ③ `**` 通配路径上的 min/max 汇总本身也不可靠 ⇒ 一律**逐设备取值再在本地汇总**。
#   ⇒ 本层三条约定（以后改指纹不许破）：
#     a) **一条查询只放一个聚合**；b) **不查 `**`**，只查设备路径 `<db>.dN`；
#     c) 取不到值 ⇒ 打印**空**，由调用方写 `ERR`（绝不静默返回 0/空串：
#        "两边都一样空"会假装一致 ⇒ 假通过）。
#   写法探测：按"名字候选 × 路径候选"逐个试，**第一个成功的就是答案**（每项通常只发 1 条查询）。
#     ⚠️ 不要在这里做"探测结果缓存"：调用方一律用 `$(wal_agg1 …)`（子 shell），
#        缓存写不回来；曾写过缓存版，离线单测直接证明它恒为空（tools 里的临时单测）。
#     · 名字候选：min/max → `min_value|max_value`，退回 `min|max`（兼容 RC7 及更早版本）
#     · 路径候选：设备路径 `<db>.dN` → 序列路径 `<db>.dN.s1`（前者是本版本实测可用的聚合口径）
# ===========================================================================
wal_agg_is_err(){ printf '%s\n' "$1" | grep -qE 'IoTDBSQLException|Exception|^[[:space:]]*Msg:|Empty set|hybrid query|inferring UDF|Status code: [0-9]+'; }
# 取"最后一个数值单元格"（聚合结果没有 Time 列 ⇒ 单列；若带 Time 列，取末列同样正确）
wal_agg_pick(){ printf '%s\n' "$1" | table_rows | head -1 | awk -F'|' '
  { for (i = NF - 1; i >= 2; i--) {
      v = $i
      gsub(/^[ \t\r]+/, "", v); gsub(/[ \t\r]+$/, "", v)
      if (v ~ /^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/) { print v; exit } } }'; }
# 聚合名候选（min/max 两种写法都试；其余聚合就是它自己）
_wal_agg_names(){ case "$1" in
    min) printf '%s\n' min_value min ;;
    max) printf '%s\n' max_value max ;;
    *)   printf '%s\n' "$1" ;; esac; }
# 单设备单聚合 ⇒ 打印数值文本；所有候选写法都失败 ⇒ 打印空串（调用方转成 ERR）
wal_agg1(){ local fn=$1 dev=$2 name path out v
  for name in $(_wal_agg_names "$fn"); do
    for path in "$dev" "$dev.s1"; do
      out=$(sq "select $name(s1) from $path;")
      wal_agg_is_err "$out" && continue
      v=$(wal_agg_pick "$out")
      [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
  done
  return 1; }
# 单设备四项（count/sum/min/max 各一条查询；取不到的项写 ERR）
wal_dev_fp4(){ local dev=$1 c s mn mx
  c=$(wal_agg1 count "$dev")
  s=$(wal_agg1 sum "$dev")
  mn=$(wal_agg1 min "$dev")
  mx=$(wal_agg1 max "$dev")
  printf 'count=%s sum=%s min=%s max=%s' "${c:-ERR}" "${s:-ERR}" "${mn:-ERR}" "${mx:-ERR}" ; }
# 逐设备汇总 min/max（**替代** `select min(s1) from <db>.**`：该写法在本版本直接 701）
wal_dev_sum_of(){ local fn=$1 db=$2 n=$3 i v s=0
  for (( i=1; i<=n; i++ )); do
    v=$(wal_agg1 "$fn" "$db.d$i")
    [ -n "$v" ] || { printf 'ERR'; return 1; }
    s=$(awk -v a="$s" -v b="$v" 'BEGIN{ x = a + b; if (x == int(x)) printf "%.0f", x; else printf "%.6f", x }')
  done
  printf '%s' "$s"; }
# d1 全序列指纹（md5 + 行数）
#   ⚠️ md5 **必须**先 `data_rows`：CLI 的原始输出里含 `It costs 0.0xx s` 统计行（每次都不同）
#      与含序列全路径的表头 ⇒ 直接喂 md5sum 会让"两相永远不等"（假 FAIL）。
#      **判据不变**：两相 `d1_seq_md5` 必须相等（这里只修取值路径）。
wal_seq_fp(){ local db=$1 raw seq
  raw=$(sq "select s1 from $db.d1 order by time;")
  if wal_agg_is_err "$raw"; then printf 'd1_seq_md5=ERR\nd1_seq_rows=ERR\n'; return 1; fi
  # 【2026-10-28】归一化掉空白：CLI 按列宽补空格，两相列宽可能差一格（实测 8000 行只差对齐空格就 md5 不同）
  seq=$(printf '%s\n' "$raw" | data_rows | tr -d ' ')
  # 【2026-10-28】指纹时刻就把归一化行落盘：后续 diff 若重新查询，数据可能已不可见（实测 NC 相拿到 EMPTY）
  if [ -n "${ART:-}" ]; then printf '%s\n' "${seq:-EMPTY}" > "$ART/d1_seq_${db}.rows"; fi
  printf 'd1_seq_md5=%s\n'  "$(printf '%s\n' "$seq" | md5sum | cut -c1-12)"
  printf 'd1_seq_rows=%s\n' "$(printf '%s\n' "$seq" | wc -l | tr -d ' ')"; }
