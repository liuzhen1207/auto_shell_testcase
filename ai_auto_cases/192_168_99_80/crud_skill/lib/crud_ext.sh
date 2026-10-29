#!/bin/bash
# ============================================================================
# 存储模块 CRUD 专项 skill —— CRUD 专属日志判据层（可选层；**默认不改变任何行为**）
#
# 背景（为什么需要这一层）：`lib/common.sh` 的 `check_logs` 是逐字节抄自"合并（compaction）专项
# skill"的，它里面有两处是**合并语义**，对 CRUD 用例不合适：
#   · 异常正则：`pat = COMMON_ERR_PAT | CMP_ERR_PAT`，其中
#     `CMP_ERR_PAT='Compaction[^|]*(failed|…) | Failed to (compaction|compact|merge) | …'`
#     —— 全是合并任务的失败模式，CRUD 的删除/加载/LastCache 失败模式一个都不覆盖；
#   · "正证据"：收尾时统计 `Compaction task starts / finishes successfully` 的累计行数
#     —— CRUD 用例里这个数**不会随用例动作增长**，打出来只会误导（"没增长"看起来像用例没生效）。
#
# 本层的做法（与 `lib/common.sh` 新增的两个**可覆盖钩子**配合，钩子是纯增量、默认空）：
#   · `CMP_ERR_PAT_CUSTOM`        追加异常正则（与 COMMON_ERR_PAT/CMP_ERR_PAT 取并集）
#   · `CMP_POSITIVE_EVIDENCE_FN`  "正证据"函数名；设置后 `check_logs` 调用**它**、
#                                 并以**替代**方式跳过合并专用的 starts/finishes 统计
# 提供的接口：
#   `crud_err_pat_extra`        CRUD 专属异常正则（建议集，逐条在 RC7 源码里核对过出处）
#   `crud_install_err_pat [re]` 安装/追加到 `CMP_ERR_PAT_CUSTOM`（**用例显式 opt-in**）
#   `crud_positive_evidence`    CRUD 版正证据（删除写入 / Load 相关 / LastCache 相关行数 + 本用例库 TsFile 数）
#   `crud_log_sum <pat>`        跨 DN 日志行数求和（正证据/断言复用）
#   `crud_check_logs [label]`   包装：装上 CRUD 正证据后调用 `check_logs`（等价于用例里 export 钩子）
#
# 用法（在用例里，**按需**）：
#   . "$HERE/../../lib/crud_ext.sh"
#   export CRUD_EVIDENCE_DB="$DB"                       # 正证据里带出本用例库的 TsFile 数（可选）
#   export CMP_POSITIVE_EVIDENCE_FN=crud_positive_evidence
#   crud_install_err_pat                                # 需要 CRUD 异常面时才装
#   … 之后 post_checks / check_logs 就会用上面的判据
#
# ⚠️ 两条纪律：
#   ① **不要全局默认启用异常正则**：CRUD 用例常有"故意触发报错"的负向相（错误码/非法 DDL），
#      广谱正则会把预期失败误判成产品问题。默认值保持空。
#   ② 钩子只在**调用 `check_logs` 时**读取（lib 是用例开头 source 的，那时用例还没 export）——
#      设置动作要放在 post_checks/check_logs 之前（与 `CMP_LOG_BENIGN_EXTRA` 同一坑，CO-16 踩过）。
#   本层不修改 `lib/common.sh` 的默认语义：不导出任何钩子时，check_logs 与合并 skill 完全一致。
# ============================================================================

# ---------------------------------------------------------------------------
# CRUD 专属异常正则（**建议集**；每条都在 RC7 源码里逐字核对过）
#   Delete ModificationFile {} failed.                     → StorageEngineMessages.java:311
#                                                            （ModificationFileV1.java:161 记 WARN）
#   Failed to read mods from {} for {}                     → StorageEngineMessages.java:492
#   Unrecognized LastCacheLoadStrategy …, fall back to CLEAN_ALL
#                                                          → StorageEngineMessages.java:757
#                                                            （DataRegion.java:5255 记 WARN）
#   Load: Query fallback failed for device …               → StorageEngineMessages.java:1579
# 说明：这些是"出现即真失败/真回退"的模式；不含 IoTDBSQLException 这类**广谱**串
#   （负向相里遍地都是），也不含 TTL/合并的既有模式（COMMON_ERR_PAT/CMP_ERR_PAT 已覆盖）。
CRUD_ERR_PAT_SUGGESTED='Delete ModificationFile .* failed|Failed to read mods from|Unrecognized LastCacheLoadStrategy|Load: Query fallback failed for device'

crud_err_pat_extra(){ printf '%s' "$CRUD_ERR_PAT_SUGGESTED"; }

# 安装（追加）CRUD 专属异常正则到 CMP_ERR_PAT_CUSTOM；不传参数就用建议集
crud_install_err_pat(){ local extra=${1:-$CRUD_ERR_PAT_SUGGESTED}
  if [ -z "$extra" ]; then warn "  crud_install_err_pat：正则为空 ⇒ 不安装（保持默认行为）"; return 0; fi
  if [ -n "${CMP_ERR_PAT_CUSTOM:-}" ]; then CMP_ERR_PAT_CUSTOM="$CMP_ERR_PAT_CUSTOM|$extra"
  else CMP_ERR_PAT_CUSTOM="$extra"; fi
  export CMP_ERR_PAT_CUSTOM
  log "  已安装 CRUD 专属异常正则（与 COMMON_ERR_PAT/CMP_ERR_PAT 取并集）：$CMP_ERR_PAT_CUSTOM"; }

# ---------------------------------------------------------------------------
# 跨 DN 日志行数求和（只读；用于正证据与"无 OOM"这类计数断言）
# ---------------------------------------------------------------------------
crud_log_sum(){ local pat=$1 h files n s=0
  for h in "${DN[@]}"; do
    files=$(sshx "$h" "ls $DB_DIR/logs/*datanode*all*.log $DB_DIR/logs/*datanode*error*.log 2>/dev/null" 2>/dev/null | tr '\n' ' ')
    [ -n "$files" ] || continue
    n=$(sshx "$h" "grep -hE '$pat' $files 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "${s:-0}"; }

# ---------------------------------------------------------------------------
# CRUD 版"正证据"（用法：export CMP_POSITIVE_EVIDENCE_FN=crud_positive_evidence）
#   与合并 skill 的 starts/finishes 对应，CRUD 关心三类事件是否真的发生：
#     ① 删除真的落到 Mod 文件（`[Deletion] Deletion {} is written into {} mod files`，源码 :738）
#     ② Load 真的执行（`Successfully auto load tsfile …` :1314 / `Data type conversion for
#        LoadTsFileStatement {} is successful.` :1274 —— 这两条是 Pipe/自动加载与类型转换路径的权威串）
#     ③ LastCache 相关行数（**只说明"日志里提到了 LastCache"，不代表命中率**：
#        矩阵 §4-C5 明确"LastCache 命中率在 RC7 没有可查指标" ⇒ 不要拿它当性能判据）
#   另：设置 `CRUD_EVIDENCE_DB=<库>` 时附带该库的 TsFile 数（文件面正证据）。
# ---------------------------------------------------------------------------
crud_positive_evidence(){ local db="${CRUD_EVIDENCE_DB:-}" del load lc n
  del=$(crud_log_sum '\[Deletion\] Deletion .* is written into')
  load=$(crud_log_sum 'Successfully auto load tsfile|Data type conversion for LoadTsFileStatement .* is successful')
  lc=$(crud_log_sum 'LastCache|last cache')
  log "  CRUD 正证据（全部 DN 日志累计）：Deletion 写入=${del:-0} Load 相关=${load:-0} LastCache 相关=${lc:-0}（LastCache 只有\"提及\"计数，命中率不可观测，见矩阵 §4-C5）"
  if [ -n "$db" ] && declare -F cmp_all_sum >/dev/null 2>&1; then
    n=$(cmp_all_sum "$db")
    log "  CRUD 正证据（库 $db）：TsFile=${n:-0}（文件面；数据面正确性由用例自己的断言负责）"
  fi
  return 0; }

# ---------------------------------------------------------------------------
# 包装：装上 CRUD 正证据后调用 check_logs（不想 export 时可直接在用例里调用它）
#   crud_check_logs [额外异常正则]   —— 额外正则会作为 check_logs 的第 1 个参数追加
# ---------------------------------------------------------------------------
crud_check_logs(){ local extra=${1:-} prev="${CMP_POSITIVE_EVIDENCE_FN:-}"
  CMP_POSITIVE_EVIDENCE_FN="${CMP_POSITIVE_EVIDENCE_FN:-crud_positive_evidence}"
  check_logs "$extra"
  CMP_POSITIVE_EVIDENCE_FN="$prev"; }
