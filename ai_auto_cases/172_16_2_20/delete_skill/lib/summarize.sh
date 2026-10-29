#!/bin/bash
# summarize.sh — 从每轮证据里抽出实际查询结果摘要，并做跨协议一致性比对
# 输出: results/summary.tsv  (proto, case, data_rows, md5)
#       results/cross-protocol-diff.txt
set -u
BASE=/data2/iotdb/rc10_matrix
OUT=$BASE/results/summary.tsv
CROSS=$BASE/results/cross-protocol-diff.txt
: > "$OUT"
norm(){ grep -vE '^(It costs|Total line number|TimechoDB|Msg:|-+$|Starting|Successfully login)' "$1" 2>/dev/null | grep -v '^[[:space:]]*$'; }

for P in IoTConsensus IoTV2; do
  for d in "$BASE"/artifacts/"$P"/*/; do
    c=$(basename "$d")
    f="$d/final-query-dn19.out"
    [ -s "$f" ] || continue
    rows=$(grep -c '^|' "$f" 2>/dev/null || echo 0)
    h=$(norm "$f" | md5sum | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\n' "$P" "$c" "$rows" "$h" >> "$OUT"
  done
done

: > "$CROSS"
awk -F'\t' '{k=$2; if($1=="IoTConsensus"){a[k]=$3; ha[k]=$4} else {b[k]=$3; hb[k]=$4}} END{
  for(k in a){ if(k in b){ if(a[k]!=b[k] || ha[k]!=hb[k]) printf "%-24s IoTConsensus rows=%s hash=%s | IoTV2 rows=%s hash=%s\n", k, a[k], substr(ha[k],1,8), b[k], substr(hb[k],1,8) } }
}' "$OUT" | sort > "$CROSS"

echo "summary_rows=$(wc -l < "$OUT") cross_mismatch=$(wc -l < "$CROSS")"
head -n 10 "$CROSS"
