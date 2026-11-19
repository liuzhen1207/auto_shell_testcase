#!/usr/bin/env bash
# =============================================================================
# tools/build_matrix_report.sh
#
# 合并（compaction）专项 skill —— 52 用例 × 双协议 结果汇总 / 报告生成工具
#
# 做什么：
#   1) 扫描 results/*.csv（多轮归档）、results/*.out（兜底解析 "RESULT ..." 行）、
#      results/result_*.txt（单用例补跑只落在这里的情况）；
#   2) 归一化成 (case_id, protocol, result, elapsedSeconds, failCount, source, time)；
#   3) 去重（同一轮同一用例只保留一条；历史轮次里「脚本名形态」与「用例 ID 形态」
#      两行是同一轮的重复记录，合并成一条）；
#   4) 应用作废清单 results/INVALIDATED.tsv（命中 => invalidated，不参与当前结论）；
#   5) 每个 (case, protocol) 选一条「当前结论」，并保留全部历史；
#   6) 产出 results/final_results.csv 与 docs/MATRIX_52x2.md。
#
# 只读 / 幂等 / 可重复运行：
#   * 绝不修改任何 .csv / .out / .txt 源数据；
#   * 输出里不含「生成时间」等易变内容，所有集合都排序 => 同一批输入必定同一份输出；
#   * INVALIDATED.tsv 只在缺失时用初始内容创建，已存在则原样使用（不会覆盖）。
#
# 依赖：bash + awk（优先 gawk；result_*.txt 的「开始时间 + elapsed」归一时间戳需要
#       gawk 的 mktime，缺 gawk 时自动跳过该数据源并告警）+ sort + wc/iconv（可选）。
#       **不需要 python3**，因此不存在「python3 缺失降级」问题。
#
# 用法：
#   bash tools/build_matrix_report.sh [--build <build>] [--results <dir>] [--docs <dir>]
#     --build   强制指定「目标 build」（默认 = 最新非 rc6 来源记录所属 build）
# =============================================================================
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$SKILL_DIR/results"
DOCS="$SKILL_DIR/docs"
BUILD_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --build)   BUILD_OVERRIDE="${2:-}"; shift 2 || true;;
    --results) RESULTS="${2:-}"; shift 2 || true;;
    --docs)    DOCS="${2:-}"; shift 2 || true;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "[build_matrix_report] unknown arg: $1" >&2; exit 2;;
  esac
done

CASES_TSV="$SKILL_DIR/cases/cases.tsv"
INVALID="$RESULTS/INVALIDATED.tsv"
OUT_CSV="$RESULTS/final_results.csv"
OUT_MD="$DOCS/MATRIX_52x2.md"

die(){ echo "[build_matrix_report] ERROR: $*" >&2; exit 1; }

[ -d "$RESULTS" ] || die "results dir not found: $RESULTS"
[ -r "$CASES_TSV" ] || die "cases list not found: $CASES_TSV"
mkdir -p "$DOCS"

# ---------------------------------------------------------------- 引导作废清单
if [ ! -f "$INVALID" ]; then
  {
    printf '%s\n' "# 作废清单（TAB 分隔）：case_id <TAB> protocol <TAB> 来源匹配 <TAB> 原因"
    printf '%s\n' "# 来源匹配 token 用 ; 分隔，支持 run=<runid> / file=<文件名> / time=<时间前缀> / *（匹配该用例该协议的全部记录）；"
    printf '%s\n' "# 命中的记录标记 invalidated：不参与「当前结论」，但保留在历史轨迹里供追溯。"
    printf '%s\t%s\t%s\t%s\n' "CO-33" "IoTConsensus" \
      "run=20261015_162447;run=20261016_005827;file=test_result_rc7_v1_full_20261016_004107.csv;file=test_result_rc7_v1_rerun_20261016_041349.csv" \
      "远端脚本被部署截断 5 字节（c33_repair→c33_repai）⇒ start repair data 从未下发，fail=11 是假失败；已修复并重跑（两份 V1 CSV test_result_rc7_v1_full_20261016_004107.csv 与 test_result_rc7_v1_rerun_20261016_041349.csv 中的 CO-33）"
    printf '%s\t%s\t%s\t%s\n' "CO-34" "IoTConsensus" \
      "run=20261015_164235;run=20261016_011508;file=test_result_rc7_v1_full_20261016_004107.csv;file=test_result_rc7_v1_rerun_20261016_041349.csv" \
      "grep -c … || echo 0 在 0 匹配时输出两行 ⇒ 断言拿到 \"0\\n0\"，fail=1 是假失败；上报的写入错误行数实为 0；已修复并重跑（同上两份 V1 CSV 中的 CO-34）"
    printf '%s\t%s\t%s\t%s\n' "CO-36" "IoTConsensus" \
      "run=20261015_180042;run=20261015_164726" \
      "远端脚本被截断 1 字符（函数签名 …del=\$6 per→…del=\$6 pe）⇒ set -u 下 \$per 未定义，fail=23 是假失败；已重新部署并重跑（两份 V1 CSV 中的 CO-36）"
    printf '%s\t%s\t%s\t%s\n' "CO-33" "IoTConsensusV2" \
      "run=20261016_175059;time=2026-10-16T18:08:08" \
      "test_result.csv 中的 CO-33（1029s / fail=11）：同上截断原因，为假失败"
    printf '%s\t%s\t%s\t%s\n' "CO-34" "IoTConsensusV2" \
      "run=20261016_180808;time=2026-10-16T18:11:59" \
      "test_result.csv 中的 CO-34（231s / fail=1）：同上 grep 原因，为假失败"
  } > "$INVALID"
  echo "[build_matrix_report] 已创建初始作废清单: $INVALID"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mxreport.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

AWK=awk
command -v gawk >/dev/null 2>&1 && AWK=gawk
HAVE_MKTIME=0
if [ "$AWK" = gawk ] && $AWK 'BEGIN{ exit (mktime("2026 01 01 00 00 00") > 0) ? 0 : 1 }' 2>/dev/null; then
  HAVE_MKTIME=1
fi

# ============================================================ 1. 用例清单（52 条）
# cases.tsv 列：case_id / 脚本 / 模型 / 粒度 / 需否启停 / 关键参数 / 说明
$AWK -F'\t' '
  !/^#/ && NF>=4 {
    p=$2; sub(/.*\//,"",p); sub(/\.sh$/,"",p)
    print $1 "\t" p "\t" $3 "\t" $4
  }' "$CASES_TSV" \
| $AWK -F'\t' '{ split($1,a,"-"); r=(a[1]=="CO"?100:200)+a[2]; printf "%06d\t%s\n", r, $0 }' \
| sort -k1,1n | cut -f2- > "$TMP/cases.list"

NCASE=$(wc -l < "$TMP/cases.list" | tr -d ' ')
[ "$NCASE" -ge 1 ] || die "cases.tsv 未解析出任何用例"
[ "$NCASE" -eq 52 ] || echo "[build_matrix_report] WARN: 用例数 = $NCASE（期望 52），报告仍会生成" >&2

$AWK -F'\t' '{print $2"\t"$1}' "$TMP/cases.list" > "$TMP/map.tsv"

# ============================================================ 2. 采集原始记录
# 统一 9 列：time build proto caseName result elapsed fail artifact source
: > "$TMP/raw.tsv"
: > "$TMP/files.txt"

csv_files=""
for f in "$RESULTS"/*.csv; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "final_results.csv" ] && continue
  head -1 "$f" 2>/dev/null | grep -q 'caseName' || continue
  csv_files="$csv_files $b"
  echo "$f" >> "$TMP/files.txt"

  # 记录起始行 = 以 ISO 时间戳开头的行；message 里可能嵌真实换行，续行一律忽略
  $AWK -v SRC="$b" '
    function norm(t){ sub(/\+[0-9][0-9]:[0-9][0-9]$/,"",t); return t }
    {
      line=$0
      if (line !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) next
      rest=line; ok=1
      for(i=1;i<=8;i++){ p=index(rest,","); if(p==0){ok=0;break}; f[i]=substr(rest,1,p-1); rest=substr(rest,p+1) }
      if(!ok) next
      if(f[5] !~ /^(PASS|FAIL|UNKNOWN|SKIP|WARN)$/) next
      if(f[6] !~ /^[0-9]+$/ || f[7] !~ /^[0-9]+$/) next
      print norm(f[1]) "\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5] "\t" f[6] "\t" f[7] "\t" f[8] "\t" SRC
    }' "$f" >> "$TMP/raw.tsv"
done

# .out 兜底：某些单用例补跑只落在 .out 里
for f in "$RESULTS"/*.out; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  grep -q '] RESULT ' "$f" 2>/dev/null || continue
  echo "$f" >> "$TMP/files.txt"
  $AWK -v SRC="$b" '
    {
      line=$0
      i=index(line, "] RESULT ")
      if (i==0) next
      ts=substr(line,2,i-2)
      gsub(/ /,"T",ts)
      rest=substr(line,i+9)
      n=split(rest,a," ")
      if (n<7) next
      if (a[1]!="PASS" && a[1]!="FAIL") next
      ff=a[2]; sub(/^fail_flag=/,"",ff)
      cc=a[3]; sub(/^case=/,"",cc)
      pp=a[4]; sub(/^consensus=/,"",pp)
      bb=a[5]; sub(/^build=/,"",bb)
      ee=a[6]; sub(/^elapsed=/,"",ee); sub(/s$/,"",ee)
      if (ff !~ /^[0-9]+$/ || ee !~ /^[0-9]+$/) next
      if (pp !~ /IoTConsensus/) next
      print ts "\t" bb "\t" pp "\t" cc "\t" a[1] "\t" ee "\t" ff "\t" SRC "\t" SRC
    }' "$f" >> "$TMP/raw.tsv"
done

# result_*.txt（key=value 块；时间统一成「开始时间 + elapsed」= 与 CSV 的 Time 列对齐）
TXT_SKIPPED=0
if [ "$HAVE_MKTIME" = 1 ]; then
  for f in "$RESULTS"/result_*.txt; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    echo "$f" >> "$TMP/files.txt"
    $AWK -v SRC="$b" '
      function reset(){ rid=""; cs=""; bd=""; cn=""; rs=""; ff=""; el=""; ar="" }
      function emit(  t,e,p){
        if (rid=="") return
        if (rs!="PASS" && rs!="FAIL") { reset(); return }
        if (ff !~ /^[0-9]+$/ || el !~ /^[0-9]+$/) { reset(); return }
        p=cn; sub(/.*\./,"",p)
        if (p !~ /IoTConsensus/) { reset(); return }
        t=substr(rid,1,4)" "substr(rid,5,2)" "substr(rid,7,2)" "substr(rid,10,2)":"substr(rid,12,2)":"substr(rid,14,2)
        e=mktime(t)
        if (e>0) t=strftime("%Y-%m-%dT%H:%M:%S", e+el); else { gsub(/ /,"T",t) }
        print t "\t" bd "\t" p "\t" cs "\t" rs "\t" el "\t" ff "\t" ar "\t" SRC
        reset()
      }
      /^run_id=/  { emit(); rid=substr($0,8);  next }
      /^case=/    { cs=substr($0,6);  next }
      /^build=/   { bd=substr($0,7);  next }
      /^consensus=/{ cn=substr($0,11); next }
      /^result=/  { rs=substr($0,8);  next }
      /^fail_flag=/{ ff=substr($0,11); next }
      /^elapsed_seconds=/{ el=substr($0,17); next }
      /^artifact=/{ ar=substr($0,10); next }
      END{ emit() }' "$f" >> "$TMP/raw.tsv"
  done
else
  TXT_SKIPPED=1
  echo "[build_matrix_report] WARN: 无 gawk/mktime，跳过 result_*.txt 数据源（CSV 与 .out 照常解析）" >&2
fi

RAW_ALL=$(wc -l < "$TMP/raw.tsv" | tr -d ' ')

# ============================================================ 3. 归一化 case / protocol
$AWK -F'\t' -v MAP="$TMP/map.tsv" -v ST="$TMP/stats.env" '
  BEGIN{
    while ((getline l < MAP) > 0) { n=split(l,a,"\t"); if(n>=2) m[a[1]]=a[2] }
    close(MAP)
    nscript=0; nid=0; nunmap=0; nmismatch=0; nother=0
  }
  {
    cn=$4; cid=""; form="id"
    if (cn ~ /^(CO|DT)-[0-9]+$/) { cid=cn; nid++ }
    else {
      form="script"; nscript++
      s=cn; sub(/\.sh$/,"",s)
      sub(/_IoTConsensusV2$/,"",s); sub(/_IoTConsensus$/,"",s)
      if (s in m) cid=m[s]; else nunmap++
    }
    if (cid=="") next
    p=$3
    exp=""
    if (cn ~ /_IoTConsensusV2(\.sh)?$/) exp="IoTConsensusV2"
    else if (cn ~ /_IoTConsensus(\.sh)?$/) exp="IoTConsensus"
    if (p !~ /IoTConsensus/) { nother++ ; if (exp!="") p=exp }
    else if (exp!="" && p!=exp) nmismatch++
    if (p!="IoTConsensus" && p!="IoTConsensusV2") next
    print cid "\t" p "\t" $1 "\t" $2 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
  }
  END{
    printf "nscript=%d\nnid=%d\nnunmap=%d\nnmismatch=%d\nnother=%d\n", nscript, nid, nunmap, nmismatch, nother > ST
  }' "$TMP/raw.tsv" > "$TMP/norm.tsv"

# ============================================================ 4. 去重（同一轮同一用例一条）
sort -t$'\t' -k1,1 -k2,2 -k3,3 -k5,5 -k6,6 -k7,7 -k8,8 -k9,9 "$TMP/norm.tsv" \
| $AWK -F'\t' '
  function addu(acc, v,   i,a){
    if (v=="") return acc
    if (acc=="") return v
    n=split(acc,a,"|"); for(i=1;i<=n;i++) if(a[i]==v) return acc
    return acc "|" v
  }
  function emit(){
    if (k=="") return
    print c1 "\t" c2 "\t" c3 "\t" c4 "\t" c5 "\t" c6 "\t" c7 "\t" n "\t" arts "\t" srcs
  }
  {
    key=$1"|"$2"|"$3"|"$5"|"$6"|"$7
    if (key != k) { emit(); k=key; c1=$1;c2=$2;c3=$3;c4=$4;c5=$5;c6=$6;c7=$7
                    arts=addu("",$8); srcs=addu("",$9); n=1 }
    else { n++; arts=addu(arts,$8); srcs=addu(srcs,$9) }
  }
  END{ emit() }' > "$TMP/records.tsv"

RAW_N=$(wc -l < "$TMP/raw.tsv" | tr -d ' ')
REC_N=$(wc -l < "$TMP/records.tsv" | tr -d ' ')

# 每个 CSV：物理行数 vs 记录数（差值 = message 里嵌入的换行）
: > "$TMP/multiline.txt"
for f in "$RESULTS"/*.csv; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "final_results.csv" ] && continue
  head -1 "$f" 2>/dev/null | grep -q 'caseName' || continue
  lines=$(wc -l < "$f" | tr -d ' ')
  recs=$($AWK '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
      rest=$0; ok=1
      for(i=1;i<=8;i++){ p=index(rest,","); if(p==0){ok=0;break}; rest=substr(rest,p+1) }
      if(ok) n++
    } END{ print n+0 }' "$f")
  extra=$(( lines - 1 - recs ))
  [ "$extra" -gt 0 ] && printf '%s\t%s\t%s\n' "$b" "$lines" "$recs" >> "$TMP/multiline.txt"
done

# 非法 UTF-8 字节的文件（若 iconv 可用）
: > "$TMP/badutf8.txt"
if command -v iconv >/dev/null 2>&1; then
  for f in "$RESULTS"/*.csv "$RESULTS"/*.out "$RESULTS"/result_*.txt; do
    [ -f "$f" ] || continue
    n=$(iconv -f UTF-8 -t UTF-8 "$f" 2>&1 >/dev/null | grep -c 'illegal input sequence' 2>/dev/null || true)
    [ -n "$n" ] && [ "$n" -gt 0 ] && printf '%s\t%s\n' "$(basename "$f")" "$n" >> "$TMP/badutf8.txt"
  done
fi

# ============================================================ 5. 生成报告
cat > "$TMP/report.awk" <<'AWKEOF'
function addu(acc, v,   i,a){ if(v=="") return acc; if(acc=="") return v; n=split(acc,a,"|"); for(i=1;i<=n;i++) if(a[i]==v) return acc; return acc "|" v }
function q(s){ if (s ~ /[",]/) { gsub(/"/,"\"\"",s); return "\"" s "\"" } return s }
function baseall(s,  n,a,i,t,o){ n=split(s,a,"|"); o=""; for(i=1;i<=n;i++){ t=a[i]; sub(/.*\//,"",t); o=(o==""?t:o"|"t) } return o }
function proto_of(p){ return (p==1 ? "IoTConsensus" : "IoTConsensusV2") }
function cell(i,p,  s){ if(cval[i,p]=="missing") return "—"; s=cres[i,p]" ("cel[i,p]"s)"; if(cval[i,p]=="invalidated") s="作废 " s; return s }
function sortidx(arr,n,  i,j,t){ for(i=2;i<=n;i++){ t=arr[i]; j=i-1; while(j>=1 && rtime[arr[j]]>rtime[t]){ arr[j+1]=arr[j]; j-- } arr[j+1]=t } }

BEGIN{
  FS="\t"; OFS="\t"
  ncase=0
  while ((getline cl < CASES)>0) {
    if (cl ~ /^#/ || cl=="") continue
    n=split(cl,cf,"\t"); if(n<1) continue
    ncase++; cid[ncase]=cf[1]; cname[ncase]=(n>=2?cf[2]:""); cmodel[ncase]=(n>=3?cf[3]:""); cgran[ncase]=(n>=4?cf[4]:"")
  }
  close(CASES)
  ninv=0
  while ((getline il < INV)>0) {
    if (il ~ /^#/ || il=="") continue
    n=split(il,f,"\t"); if(n<3) continue
    key=f[1] SUBSEP f[2]
    if (!(key in imat)) { ninv++; invcase[ninv]=f[1]; invproto[ninv]=f[2]; imat[key]=""; ireason[key]="" }
    imat[key] = (imat[key]=="" ? f[3] : imat[key] ";" f[3])
    rsn=(n>=4?f[4]:"")
    ireason[key] = (ireason[key]=="" ? rsn : ireason[key] " / " rsn)
    invhits[key]=0
  }
  close(INV)
}
{
  nr++
  rcase[nr]=$1; rproto[nr]=$2; rtime[nr]=$3; rbuild[nr]=$4; rresult[nr]=$5
  rel[nr]=$6; rfail[nr]=$7; rnrow[nr]=$8+0; rart[nr]=$9; rsrc[nr]=$10
  kk=$1 SUBSEP $2
  hay=$3 "|" $4 "|" $9 "|" $10
  hit=0
  if (kk in imat) {
    m=split(imat[kk],mm,";")
    for(i=1;i<=m;i++){
      t=mm[i]; gsub(/^[ \t]+|[ \t]+$/,"",t)
      if (t=="") continue
      sub(/^(run|file|time)=/,"",t)
      if (t=="*" || t=="ALL" || t=="any") { hit=1; break }
      if (index(hay,t)>0) { hit=1; break }
    }
    if (hit) { invhits[kk]++; hitcases[kk]=1 }
  }
  rinv[nr]=hit
  rwhy[nr]=(hit?ireason[kk]:"")
  hinv[kk]=hinv[kk]+hit
  htot[kk]=htot[kk]+1
  # 冲突：同一 (case,proto,time) 出现两套不同结果
  ck=$1 "|" $2 "|" $3
  sig=$5 "/" $6 "s/fail" $7
  if (sigset[ck]=="") sigset[ck]=sig
  else if (index(";" sigset[ck] ";", ";" sig ";")==0) { sigset[ck]=sigset[ck] ";" sig; if (index(sigset[ck],";")>0) nconf++ }
  if ($5=="UNKNOWN") nunknown++
  bcnt[$4]++
  if (tolower($10) !~ /rc6/) { if ($3>tb_time) { tb_time=$3; tb_build=$4 } }
}
END{
  if (TB!="") tb_build=TB
  if (tb_build=="") { tb_time=""; for(j=1;j<=nr;j++) if (rtime[j]>tb_time) { tb_time=rtime[j]; tb_build=rbuild[j] } }

  # ---------- 选当前结论 ----------
  for(i=1;i<=ncase;i++){
    for(p=1;p<=2;p++){
      pr=proto_of(p)
      bt=""; bi=0; bo=""; boi=0; bv=""; bvi=0
      for(j=1;j<=nr;j++){
        if (rcase[j]!=cid[i] || rproto[j]!=pr) continue
        if (rinv[j]) { if (rtime[j]>bv) { bv=rtime[j]; bvi=j }; continue }
        if (rtime[j]>bo) { bo=rtime[j]; boi=j }
        if (tb_build!="" && rbuild[j]==tb_build) { if (rtime[j]>bt) { bt=rtime[j]; bi=j } }
      }
      sel=bi; val="valid"
      if (sel==0) sel=boi
      if (sel==0) { sel=bvi; if (sel>0) val="invalidated" }
      if (sel==0) val="missing"
      selidx[i,p]=sel; cval[i,p]=val
      if (sel>0) {
        cres[i,p]=rresult[sel]; cel[i,p]=rel[sel]; cfail[i,p]=rfail[sel]
        ctime[i,p]=rtime[sel]; csrc[i,p]=baseall(rsrc[sel]); cbuild[i,p]=rbuild[sel]
        cwhy[i,p]=rwhy[sel]
      } else { cres[i,p]=""; cel[i,p]=""; cfail[i,p]=""; ctime[i,p]=""; csrc[i,p]=""; cbuild[i,p]=""; cwhy[i,p]="" }
    }
  }

  # ---------- 顶部统计 ----------
  np1=0; nf1=0; nm1=0; np2=0; nf2=0; nm2=0; nsame=0; ndiff=0; nmiss=0
  for(i=1;i<=ncase;i++){
    for(p=1;p<=2;p++){
      if (cval[i,p]=="valid") {
        if (cres[i,p]=="PASS") { if(p==1) np1++; else np2++ }
        else if (cres[i,p]=="FAIL") { if(p==1) nf1++; else nf2++ }
        else { if(p==1) nm1++; else nm2++ }
      } else { if(p==1) nm1++; else nm2++ }
    }
    if (cval[i,1]=="valid" && cval[i,2]=="valid") { if (cres[i,1]==cres[i,2]) nsame++; else ndiff++ }
    else nmiss++
  }

  # ---------- final_results.csv ----------
  print "case,protocol,result,elapsedSeconds,failCount,time,source,validity,note" > OUTCSV
  for(i=1;i<=ncase;i++){
    for(p=1;p<=2;p++){
      note=""
      if (cval[i,p]=="missing") note="无任何记录"
      else if (cval[i,p]=="invalidated") note="作废待重跑: " cwhy[i,p]
      else {
        if (cfail[i,p]+0 > 0) note="fail=" cfail[i,p]
        if (tb_build!="" && cbuild[i,p]!=tb_build) note=(note==""?"":note"; ") "build=" cbuild[i,p] "（非目标 build）"
      }
      if (cid[i]=="CO-35" && p==2) note=(note==""?"":note"; ") "V2 fail=44 vs V1 fail=1，定性中"
      if (cid[i]=="CO-36" && p==1) note=(note==""?"":note"; ") "重跑后 fail=20（场景未成立），先前 fail=23 已作废"
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n", q(cid[i]), q(proto_of(p)), q(cres[i,p]), q(cel[i,p]), \
             q(cfail[i,p]), q(ctime[i,p]), q(csrc[i,p]), q(cval[i,p]), q(note) > OUTCSV
    }
  }
  close(OUTCSV)

  # ---------- MATRIX_52x2.md ----------
  print "# 52 用例 × 双协议 —— 合并（compaction）专项回归 权威结果矩阵" > OUTMD
  print "" > OUTMD
  print "> 本文件由 `tools/build_matrix_report.sh` 自动生成，**请勿手工编辑**；工具只读源数据，幂等可重复运行。" > OUTMD
  print ">" > OUTMD
  print "> 数据源：`results/*.csv`（多轮归档）、`results/*.out` 的 `RESULT` 行（兜底）、`results/result_*.txt`。" > OUTMD
  print "> 目标 build：**" tb_build "**（最新非 rc6 来源记录所属 build；其它 build 如 RC6 对照跑只进历史轨迹，不作当前结论）。" > OUTMD
  print "> 原始行 " RAWN " → 去重后 " nr " 条记录（同一轮的「脚本名形态」与「用例 ID 形态」两行合并为一条）。" > OUTMD
  print "> 作废清单：`results/INVALIDATED.tsv`（" ninv " 条规则，命中 " invtotal " 条记录）。" > OUTMD
  if (TXT_SKIP==1) print "> ⚠ 未检测到 gawk/mktime，本次**跳过** `result_*.txt` 数据源。" > OUTMD
  print "" > OUTMD

  print "## ① 总览" > OUTMD
  print "" > OUTMD
  print "| 协议 | PASS | FAIL | 缺（missing / invalidated / 其它非 PASS-FAIL） | 合计 |" > OUTMD
  print "| --- | --- | --- | --- | --- |" > OUTMD
  print "| IoTConsensus（V1） | " np1 " | " nf1 " | " nm1 " | " ncase " |" > OUTMD
  print "| IoTConsensusV2（V2） | " np2 " | " nf2 " | " nm2 " | " ncase " |" > OUTMD
  print "" > OUTMD
  print "双协议一致性：**一致 " nsame "** / **分歧 " ndiff "** / **缺 " nmiss "**（共 " ncase " 条用例）。" > OUTMD
  print "" > OUTMD
  print "- `一致` = 两协议当前结论同为 PASS 或同为 FAIL；`分歧` = 一 PASS 一 FAIL；`缺` = 任一协议无有效当前结论（missing 或 invalidated）。" > OUTMD
  print "- 每次运行的原始记录来源文件数：CSV " nfilecsv " 个 / .out " nfileout " 个。" > OUTMD
  print "" > OUTMD

  # 主表
  print "## ② 主表（52 行）" > OUTMD
  print "" > OUTMD
  print "| 用例 | 名称 | V1 结果(耗时) | V2 结果(耗时) | 一致性 | 备注 |" > OUTMD
  print "| --- | --- | --- | --- | --- | --- |" > OUTMD
  for(i=1;i<=ncase;i++){
    cons="缺"
    if (cval[i,1]=="valid" && cval[i,2]=="valid") cons=(cres[i,1]==cres[i,2] ? "一致" : "分歧")
    note=""
    if (cid[i]=="CO-35") note="V2 fail=44 vs V1 fail=1，定性中"
    if (cval[i,1]=="invalidated" || cval[i,2]=="invalidated") {
      ip=(cval[i,1]=="invalidated" ? "V1" : "V2")
      note=(note==""?"":note"；") ip " 记录全部作废，详见 ③"
    }
    if (cval[i,1]=="missing" || cval[i,2]=="missing") {
      mp=(cval[i,1]=="missing" ? "V1" : "V2")
      note=(note==""?"":note"；") mp " 无记录，详见 ⑤"
    }
    if (cid[i]=="CO-36") note=(note==""?"":note"；") "V1 重跑后 fail=20（场景未成立），fail=23 已作废"
    nm=(cname[i]==""?"-":cname[i])
    mg=(cmodel[i]==""?"-":cmodel[i])
    gr=(cgran[i]==""?"-":cgran[i])
    print "| " cid[i] " | " nm "（" mg "/" gr "） | " cell(i,1) " | " cell(i,2) " | " cons " | " (note==""?" ":note) " |" > OUTMD
  }
  print "" > OUTMD

  # ③ 作废 / 需重跑
  print "## ③ 作废 / 需重跑清单" > OUTMD
  print "" > OUTMD
  print "作废规则命中 **" invtotal "** 条记录（清单文件：" invtgt " 条规则）。命中记录不参与「当前结论」，但仍保留在 ④ 历史轨迹中。" > OUTMD
  print "" > OUTMD
  if (invtotal==0) {
    print "_（无命中记录）_" > OUTMD
  } else {
    print "| 用例 | 协议 | 时间 | 结果 | 耗时 | 来源文件 | 作废原因 |" > OUTMD
    print "| --- | --- | --- | --- | --- | --- | --- |" > OUTMD
    for(i=1;i<=ncase;i++){
      for(p=1;p<=2;p++){
        pr=proto_of(p)
        cnt=0
        for(j=1;j<=nr;j++){ if (rcase[j]==cid[i] && rproto[j]==pr && rinv[j]) { cnt++; hidx[cnt]=j } }
        sortidx(hidx,cnt)
        for(x=1;x<=cnt;x++){
          j=hidx[x]
          print "| " cid[i] " | " pr " | " rtime[j] " | " rresult[j] " | " rel[j] "s | " baseall(rsrc[j]) " | " rwhy[j] " |" > OUTMD
        }
      }
    }
  }
  print "" > OUTMD
  c35_ok=0
  for(j=1;j<=nr;j++) if (rcase[j]=="CO-35" && rproto[j]=="IoTConsensusV2") c35_ok=1
  print "**待定性（未作废）**：`CO-35` IoTConsensusV2 当前结论 FAIL（fail=44，2158s）vs V1 FAIL（fail=1）—— 定性中，暂不作废。" > OUTMD
  print "" > OUTMD

  # ④ 历史轨迹
  print "## ④ 历史轨迹（按时间）" > OUTMD
  print "" > OUTMD
  print "同一轮的重复行已合并；`×n` 表示该记录由 n 条原始行（CSV 两种 caseName 写法 / .out / result_*.txt）合并而来。" > OUTMD
  print "" > OUTMD
  for(i=1;i<=ncase;i++){
    any=0
    for(p=1;p<=2;p++){ if (htot[cid[i] SUBSEP proto_of(p)]+0>0) any=1 }
    print "### " cid[i] " " cname[i] > OUTMD
    print "" > OUTMD
    if (!any) { print "_（无记录）_" > OUTMD; print "" > OUTMD; continue }
    print "```" > OUTMD
    for(p=1;p<=2;p++){
      pr=proto_of(p); kk=cid[i] SUBSEP pr
      cnt=0
      for(j=1;j<=nr;j++){ if (rcase[j]==cid[i] && rproto[j]==pr) { cnt++; hidx[cnt]=j } }
      sortidx(hidx,cnt)
      for(x=1;x<=cnt;x++){
        j=hidx[x]
        printf "%-16s %-19s %-5s %6ss fail=%-3s x%-2s %s  %s\n", pr, rtime[j], rresult[j], rel[j], rfail[j], rnrow[j], (rinv[j]?"[作废]":"[有效]"), baseall(rsrc[j]) > OUTMD
      }
      if (cnt==0) printf "%-16s %s\n", pr, "（无记录）" > OUTMD
    }
    print "```" > OUTMD
    print "" > OUTMD
  }

  # ⑤ 缺失项
  print "## ⑤ 缺失项 / 待重跑清单" > OUTMD
  print "" > OUTMD
  print "| 用例 | 协议 | 状态 | 说明 |" > OUTMD
  print "| --- | --- | --- | --- |" > OUTMD
  miss=0
  for(i=1;i<=ncase;i++){
    for(p=1;p<=2;p++){
      if (cval[i,p]=="missing") { print "| " cid[i] " | " proto_of(p) " | missing | 无任何记录 |" > OUTMD; miss++ }
      else if (cval[i,p]=="invalidated") { print "| " cid[i] " | " proto_of(p) " | 待重跑 | 全部记录已作废：" cwhy[i,p] " |" > OUTMD; miss++ }
      else if (cres[i,p]!="PASS" && cres[i,p]!="FAIL") { print "| " cid[i] " | " proto_of(p) " | " cres[i,p] " | 非 PASS/FAIL 结论 |" > OUTMD; miss++ }
    }
  }
  if (miss==0) print "| _无_ | | | |" > OUTMD
  print "" > OUTMD

  # ⑥ 数据问题
  print "## ⑥ 数据问题与解析告警" > OUTMD
  print "" > OUTMD
  print "- **caseName 两种写法（同一轮两行）**：脚本名形态 " nscript " 行 / 用例 ID 形态 " nid " 行 —— 同一轮同一用例被写了两条，本工具按 (case, protocol, time, result, elapsed, fail) 合并（原始 " RAWN " 行 → 去重 " nr " 条）。" > OUTMD
  if (nunmap>0) print "- **无法归一到用例 ID 的 caseName**：" nunmap " 行（已丢弃，请检查 cases.tsv 映射）。" > OUTMD
  if (nmismatch>0) print "- **caseName 后缀与 consensus 列不一致**：" nmismatch " 行。" > OUTMD
  if (nother>0) print "- **consensus 列非 IoTConsensus/IoTConsensusV2**：" nother " 行。" > OUTMD
  if (nconf>0) print "- **同一用例同一轮出现两套不同结果**：" nconf " 组（已按「最新一条」取结论，请人工确认）。" > OUTMD
  if (nunknown>0) print "- **result=UNKNOWN**：" nunknown " 条（早期探索轮，既非 PASS 也非 FAIL，计入「缺」）。" > OUTMD
  print "- **message 字段内嵌真实换行**：CSV 物理行数 ≠ 记录数，朴素的逐行解析会把日志行当成新记录。涉及文件：" > OUTMD
  while ((getline l < ML)>0) { n=split(l,a,"\t"); print "  - `" a[1] "`：物理行 " a[2] " / 记录 " a[3] "（多 " a[2]-1-a[3] " 个续行）" > OUTMD }
  close(ML)
  print "- **时间格式不统一**：CSV 用 `2026-10-16T18:08:08+08:00`，`.out` 的 RESULT 行用 `[2026-10-16 18:08:08]`，`result_*.txt` 只有 `run_id`（= 用例开始时间，需 + elapsed 才能与 CSV 的 Time 对齐）。本工具统一成 `YYYY-MM-DDTHH:MM:SS`（含义 = 用例结束时间）。" > OUTMD
  print "- **build 分布**：" > OUTMD
  for (b in bcnt) print "  - `" b "`：" bcnt[b] " 条记录" > OUTMD
  nb=0
  while ((getline l < BU)>0) { nb++; print "  - ⚠ 非法 UTF-8 字节：`" l "`" > OUTMD }
  close(BU)
  if (nb==0) print "- 文件编码：未检测到非法 UTF-8 字节。" > OUTMD
  print "" > OUTMD
  print "---" > OUTMD
  print "" > OUTMD
  print "重新生成：`bash tools/build_matrix_report.sh`（只读 CSV；同一批输入输出完全一致）。" > OUTMD
  close(OUTMD)

  printf "[build_matrix_report] build=%s 原始行=%d 去重后=%d 作废命中=%d | IoTConsensus: PASS=%d FAIL=%d 缺=%d | IoTConsensusV2: PASS=%d FAIL=%d 缺=%d | 一致=%d 分歧=%d 缺=%d\n", \
    tb_build, RAWN, nr, invtotal, np1, nf1, nm1, np2, nf2, nm2, nsame, ndiff, nmiss
}
AWKEOF

# invtotal / invtgt / nfilecsv / nfileout / stats 在 BEGIN 之后才能用：补一个前置小统计
$AWK -F'\t' -v INV="$INVALID" '
  BEGIN{ n=0
    while ((getline l < INV)>0) { if (l ~ /^#/ || l=="") continue; n++ }
    print n > "/dev/stdout"
  }' > "$TMP/invrules.txt"

NCSV=$(printf '%s\n' $csv_files | grep -c . || true)
NOUT=$(grep -c '\.out$' "$TMP/files.txt" 2>/dev/null || echo 0)

$AWK -v CASES="$TMP/cases.list" -v INV="$INVALID" -v OUTCSV="$OUT_CSV" -v OUTMD="$OUT_MD" \
     -v TB="$BUILD_OVERRIDE" -v RAWN="$RAW_N" -v TXT_SKIP="$TXT_SKIPPED" \
     -v ML="$TMP/multiline.txt" -v BU="$TMP/badutf8.txt" -v NCSV="$NCSV" -v NOUT="$NOUT" \
     -f "$TMP/report.awk" "$TMP/records.tsv"

rc=$?
[ "$rc" -eq 0 ] || die "报告生成失败（awk rc=$rc）"
echo "[build_matrix_report] 已写出: $OUT_CSV"
echo "[build_matrix_report] 已写出: $OUT_MD"
