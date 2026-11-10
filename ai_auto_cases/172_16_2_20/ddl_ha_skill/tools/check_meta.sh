#!/bin/bash
# check_meta.sh <case_dir> <db> <expect_object> <expect_value>
# 校验：5 台 DN 上 SHOW TABLES / SHOW CREATE TABLE 是否一致 + 期望对象是否符合
set -u
. "$(dirname "$0")/lib.sh"

CASE_DIR=$1; DB=$2; OBJ=$3; VAL=${4:-}
OUT=$CASE_DIR/meta-consistency.txt
: > "$OUT"

# 表名列表（SHOW TABLES 第一列，去表头，排序）
tables_of() {
  qdn "$1" "SHOW TABLES FROM $DB;" 2>&1 \
    | grep -E '^\|' \
    | awk -F'|' 'NF>=3 {gsub(/ /,"",$2); if ($2!="" && $2!="TableName") print $2}' \
    | sort
}

# TTL 值（SHOW TABLES 第二列，针对表 t）
ttl_of() {
  qdn "$1" "SHOW TABLES FROM $DB;" 2>&1 \
    | grep -E '^\|' \
    | awk -F'|' 'NF>=3 {gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="'"${2:-t}"'") print $3}'
}

# SHOW CREATE TABLE 全文（压空白）
create_of() {
  qdn "$1" "SHOW CREATE TABLE $DB.$2;" 2>&1 \
    | grep -E '^\|' | grep -viE '^\|[[:space:]]*(\||Table|-)' \
    | sed 's/[[:space:]]\+/ /g'
}

sig=$CASE_DIR/.meta-sig
: > "$sig"

for n in $DNS; do
  tl=$(tables_of "$n" | tr '\n' ';')
  cr=$(create_of "$n" t | tr '\n' ';')
  vw=$(create_of "$n" "$VIEW" 2>/dev/null | tr '\n' ';')
  echo "DN$n|tables=$tl|create_t=$cr|create_view=$vw" >> "$OUT"
  printf '%s\n' "$tl$cr$vw" >> "$sig"
done

uniq_cnt=$(sort -u "$sig" | wc -l)
rm -f "$sig"

# 可读性门禁：全部 DN 都连不上时，"一致"没有意义
READABLE=0
for n in $DNS; do
  qdn "$n" "SHOW DATABASES;" 2>&1 | grep -qE '^\||executed successfully' && READABLE=$((READABLE+1))
done
echo "READABLE_DNS=$READABLE/5" >> "$OUT"

if [ "$READABLE" -lt 3 ]; then
  echo "META_CONSISTENT=UNKNOWN" >> "$OUT"
elif [ "$uniq_cnt" -eq 1 ]; then
  echo "META_CONSISTENT=YES" >> "$OUT"
else
  echo "META_CONSISTENT=NO" >> "$OUT"
fi

case "$OBJ" in
  table_exists)
    tables_of 19 | grep -qx "$VAL" && e=YES || e=NO ;;
  table_absent)
    tables_of 19 | grep -qx "$VAL" && e=NO || e=YES ;;
  view_exists)
    tables_of 19 | grep -qx "$VAL" && e=YES || e=NO ;;
  view_absent)
    tables_of 19 | grep -qx "$VAL" && e=NO || e=YES ;;
  db_absent)
    # 库已删：要么报 does not exist，要么返回空结果（两种都算已删除）
    c=0
    for n in $DNS; do
      out=$(qdn "$n" "SHOW TABLES FROM $DB;" 2>&1)
      if printf '%s' "$out" | grep -qiE 'does not exist|not exist'; then c=$((c+1)); continue; fi
      rows=$(printf '%s\n' "$out" | grep -E '^\|' | grep -viE '^\|[[:space:]]*(TableName|-)' | grep -c '[A-Za-z0-9]' || true)
      [ "${rows:-0}" -eq 0 ] && c=$((c+1))
    done
    [ "$c" -eq 5 ] && e=YES || e=NO ;;
  column_present)
    create_of 19 t | grep -q "\"$VAL\"" && e=YES || e=NO ;;
  column_type)
    col=${VAL%%:*}; typ=${VAL##*:}
    create_of 19 t | grep -qi "\"$col\" $typ" && e=YES || e=NO ;;
  ttl)
    t=$(ttl_of 19 t)
    [ "$t" = "$VAL" ] && e=YES || e=NO
    echo "TTL_ACTUAL=$t EXPECT_TTL=$VAL" >> "$OUT" ;;
  devices_deleted)
    qdn 19 "SELECT count(*) FROM $DB.t WHERE dev='$VAL';" 2>&1 | grep -qE '^\|[[:space:]]*0\|' && e=YES || e=NO ;;
  *) e=NA ;;
esac
echo "EXPECT_OBJ=$OBJ EXPECT_VALUE=$VAL EXPECT_OK=$e" >> "$OUT"
