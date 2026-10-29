#!/bin/bash
# memleak_analyze.sh — 内存泄漏专项稳态分析
# 预热段（cycle 0..WARM）不计入斜率；只拟合 WARM..END 的 post-GC 堆
set -u
BASE=/data2/iotdb/rc10_matrix
WARM=${WARM:-40}
THRESH=${THRESH:-50}
DNS="19 21 22 23 24"
OUT=$BASE/studies/analysis.txt
: > "$OUT"

printf '%-26s %-4s %8s %8s %8s %10s %12s %s\n' CASE DN "heap@0" "heap@${WARM}" "heap@end" "warmup_KB" "steady_KB/cyc" VERDICT >> "$OUT"

for d in "$BASE"/studies/DEL-MEMLEAK-*/; do
  [ -f "$d/post-gc-heap.csv" ] || continue
  c=$(basename "$d")
  case_verdict="STABLE"
  for n in $DNS; do
    line=$(awk -F, -v N="$n" -v W="$WARM" -v T="$THRESH" '
      $2==N && $3!="NA" { cyc[++m]=$1; h[m]=$3 }
      END{
        if(m<3){ print "NA NA NA NA NA NO_DATA"; exit }
        first=h[1]; w=0; wv="NA"
        for(i=1;i<=m;i++){ if(cyc[i]<=W){ w=i; wv=h[i] } }
        if(w<1){ w=1; wv=h[1] }
        sx=0; sy=0; sxx=0; sxy=0; k=0
        for(i=w;i<=m;i++){ sx+=cyc[i]; sy+=h[i]; sxx+=cyc[i]*cyc[i]; sxy+=cyc[i]*h[i]; k++ }
        den=k*sxx-sx*sx
        slope=(den==0)?0:(k*sxy-sx*sy)/den
        s=slope; if(s<0) s=-s
        v=(s>T)?"LEAK_SUSPECT":"STABLE"
        printf "%d %d %d %d %.1f %s\n", first, wv, h[m], wv-first, slope, v
      }' "$d/post-gc-heap.csv")
    set -- $line
    printf '%-26s %-4s %8s %8s %8s %10s %12s %s\n' "$c" "$n" "$1" "$2" "$3" "$4" "$5" "$6" >> "$OUT"
    [ "${6:-}" = "LEAK_SUSPECT" ] && case_verdict="LEAK_SUSPECT"
  done
  echo "CASE_SUMMARY $c $case_verdict" >> "$OUT"
done

cat "$OUT"
