#!/bin/bash
# 修复被 CO-10 探测写坏的 conf（空值会让 DN 热加载/启动失败）：
# 用 conf_orig 还原 properties，再确认没有 `key=` 空值行
V=v20121rc6_1010_7ae8713e
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  echo "=== $h ==="
  ssh -o BatchMode=yes root@$h "cd /data/iotdb/$V || exit 1
    cp -p conf/iotdb-system.properties /tmp/broken_$(date +%s).properties 2>/dev/null
    rm -rf conf && cp -rp conf_orig conf
    echo -n '空值行数: '; grep -cE '^[a-z_]+=\$' conf/iotdb-system.properties
    echo -n 'compaction_priority: '; grep -E '^compaction_priority=' conf/iotdb-system.properties || echo '(未显式设置，OK)'
    echo -n 'conf 文件数: '; ls conf | wc -l"
done
echo "=== 还原后启动集群（框架脚本，带超时）==="
cd /data/iotdb/autotest || exit 1
timeout 420 bash prepare_env/start_cluster_v20.sh > /tmp/restart_after_fix.log 2>&1
echo "start rc=$?"
tail -n 5 /tmp/restart_after_fix.log
