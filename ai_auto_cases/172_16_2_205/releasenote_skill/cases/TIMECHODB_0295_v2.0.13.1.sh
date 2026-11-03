#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0295】metaDataCacheEnable=false 时，DN 启动报 NPE
#   （DataNodeMemoryConfig.initQueryEngineMemoryAllocate 使用未赋值的 memory manager）
#   验证版本：2.0.13.1 / ab6d3de
#   判据：把某台 DN 的 metaDataCacheEnable 设为 false 后重启，进程能起来、集群仍 8/8；
#         结束后恢复 true 并重启该 DN。
# ============================================================================
RN0295_IP=172.16.2.6
RN0295_CONF=""

case_RN115() {
  local n before
  before=$(T "show cluster;" 2>/dev/null | grep -c Running)
  echo "  当前 Running=$before"

  ssh -o StrictHostKeyChecking=no root@$RN0295_IP "f=/data1/iotdb/$NEW/conf/iotdb-system.properties; cp -f \$f \$f.rn0295.bak; if grep -q '^meta_data_cache_enable=' \$f; then sed -i 's/^meta_data_cache_enable=.*/meta_data_cache_enable=false/' \$f; else echo 'meta_data_cache_enable=false' >> \$f; fi; grep -n '^meta_data_cache_enable=' \$f" 2>/dev/null

  ssh -o StrictHostKeyChecking=no root@$RN0295_IP "bash /tmp/dn_restart.sh $NEW > /tmp/dn_0295.log 2>&1" 2>/dev/null
  sleep 25

  n=$(ssh -o StrictHostKeyChecking=no root@$RN0295_IP "ps -eo args | grep -cF 'com.timecho.iotdb.DataNode'" 2>/dev/null)
  echo "  重启后 DN 进程行数=$n"
  if [ "${n:-0}" -ge 1 ]; then
    ok "metaDataCacheEnable=false 下 DN 能启动"
  else
    fail "metaDataCacheEnable=false 下 DN 启动失败"
    tail -5 /tmp/dn_0295.log 2>/dev/null | sed 's/^/    /'
  fi

  # 等集群回到 8/8
  if wait_running 300 >/dev/null 2>&1; then
    ok "集群恢复 8/8"
  else
    fail "集群未恢复到 8/8（$(T "show cluster;" 2>/dev/null | grep -c Running)）"
  fi

  # 恢复配置并重启该 DN
  ssh -o StrictHostKeyChecking=no root@$RN0295_IP "f=/data1/iotdb/$NEW/conf/iotdb-system.properties; if [ -f \$f.rn0295.bak ]; then mv -f \$f.rn0295.bak \$f; else sed -i '/^meta_data_cache_enable=false$/d' \$f; fi" 2>/dev/null
  ssh -o StrictHostKeyChecking=no root@$RN0295_IP "bash /tmp/dn_restart.sh $NEW > /tmp/dn_0295r.log 2>&1" 2>/dev/null
  wait_running 300 >/dev/null 2>&1 || true
  echo "  恢复后 Running=$(T "show cluster;" 2>/dev/null | grep -c Running)"
}

CASES+=(
"RN-115|TIMECHODB-0295 启动健壮性|可靠性|metaDataCacheEnable=false 时 DataNode 仍能正常启动|case_RN115"
)
