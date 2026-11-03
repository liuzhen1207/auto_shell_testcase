#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0365】不断创建"连接不上"的 session，客户端很快 OOM
#   （底层：NodesSupplier 周期性重连线程不断创建，导致 native thread 耗尽）
#   验证版本：2.0.13.1 / ab6d3de
#   判据：向不可达端口连续连接 40 次后，客户端进程不 OOM、堆占用受控（< 512MB）、能正常退出
# ============================================================================
RN0365_CLASSES=/data2/auto_test/releasenote_skill/cases/.jdbc_classes

case_RN117() {
  local cp out heap threads
  cp=$(ls /data2/iotdb/$NEW/lib/timechodb-server-*.jar 2>/dev/null | head -1):/data2/iotdb/$NEW/lib/common-dependency.jar
  mkdir -p "$RN0365_CLASSES"
  cp /tmp/RnLeak.java "$RN0365_CLASSES/" 2>/dev/null
  ( cd "$RN0365_CLASSES" && javac -encoding UTF-8 -nowarn -cp "$cp" -d . RnLeak.java 2>&1 | head -3 )
  [ -f "$RN0365_CLASSES/RnLeak.class" ] || { fail "RnLeak 编译失败"; return 1; }

  # 6668 无监听：模拟"服务端连不上"
  out=$(timeout 180 java -Xmx256m -cp "$cp:$RN0365_CLASSES" RnLeak unreachable 127.0.0.1 6668 40 2>&1)
  echo "  结果：$(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"

  if echo "$out" | grep -qi 'OutOfMemoryError'; then
    fail "出现 OutOfMemoryError（缺陷未修复）"
    return 1
  fi
  if echo "$out" | grep -q 'LEAK_CHECK'; then
    ok "40 次不可达连接后进程正常结束，无 OOM"
  else
    fail "未拿到 LEAK_CHECK 结果（可能超时或崩溃）"
    return 1
  fi

  heap=$(echo "$out" | grep -oE 'heapUsedMB=[0-9]+' | cut -d= -f2)
  threads=$(echo "$out" | grep -oE 'threads=[0-9]+' | cut -d= -f2)
  echo "  堆占用=${heap}MB 线程数=${threads}"
  if [ "${heap:-9999}" -lt 512 ]; then ok "堆占用 ${heap}MB < 512MB"; else fail "堆占用 ${heap}MB 过高"; fi
  if [ "${threads:-9999}" -lt 300 ]; then ok "线程数 ${threads} < 300（无爆炸式增长）"; else fail "线程数 ${threads} 过多"; fi
}

CASES+=(
"RN-117|TIMECHODB-0365 客户端稳定性|可靠性|反复创建不可达 session 不应 OOM/线程暴涨|case_RN117"
)
