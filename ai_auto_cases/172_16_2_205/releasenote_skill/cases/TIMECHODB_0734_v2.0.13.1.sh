#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0734】[JDBC] ResultSet.findColumn() 树模型/表模型处理不一致，
#   按 JDBC 规范，ResultSet 无列时应抛 SQLException（原树模型直接 NPE）
#   验证版本：2.0.13.1 / ab6d3de
#   判据：空结果集上 findColumn 不得抛 NullPointerException；抛 SQLException 视为符合 JDBC
# ============================================================================
RN0734_DB=root.rn0734
RN0734_CLASSES=/data2/auto_test/releasenote_skill/cases/.jdbc_classes

case_RN112() {
  local cp out
  cp=$(ls /data2/iotdb/$NEW/lib/timechodb-server-*.jar 2>/dev/null | head -1):/data2/iotdb/$NEW/lib/common-dependency.jar
  mkdir -p "$RN0734_CLASSES"
  cp /tmp/RnJdbc.java "$RN0734_CLASSES/" 2>/dev/null
  ( cd "$RN0734_CLASSES" && javac -encoding UTF-8 -nowarn -cp "$cp" -d . RnJdbc.java 2>&1 | head -3 )
  if [ ! -f "$RN0734_CLASSES/RnJdbc.class" ]; then
    fail "RnJdbc 编译失败"
    return 1
  fi

  out=$(java -cp "$cp:$RN0734_CLASSES" RnJdbc findcolumn 127.0.0.1 6667 root "$PW" "$RN0734_DB" 2>&1)
  echo "  findColumn 结果：$(echo "$out" | tr '\n' ' ' | cut -c1-220)"

  if echo "$out" | grep -qi 'NullPointerException'; then
    fail "空结果集上 findColumn 抛 NPE（缺陷未修复）"
  else
    ok "不再抛 NPE"
  fi
  if echo "$out" | grep -q 'FINDCOLUMN_OK'; then
    ok "返回列下标（表/树实现一致，不再抛异常）"
  elif echo "$out" | grep -qi 'SQLException'; then
    ok "抛 SQLException（符合 JDBC 规范）"
  else
    fail "既未返回下标也未抛 SQLException（实际 $(echo "$out" | head -1 | cut -c1-120)）"
  fi

  T "drop database $RN0734_DB" >/dev/null 2>&1
}

CASES+=(
"RN-112|TIMECHODB-0734 JDBC|功能|空 ResultSet 上 findColumn 不应抛 NPE（返回列号或 SQLException）|case_RN112"
)
