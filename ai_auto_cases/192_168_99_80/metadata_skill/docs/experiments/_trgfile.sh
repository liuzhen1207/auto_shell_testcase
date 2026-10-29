#!/bin/bash
# 检查 trigger 是否写到了默认路径（说明 fire() 用的是新实例、onCreate 设置的字段没带过来）
for h in 192.168.99.77 192.168.99.78 192.168.99.79; do
  echo "=== $h ==="
  ssh -n -o BatchMode=yes root@$h "ls -l /tmp/mdskill_*.log 2>/dev/null; echo '--- mdskill_trigger.log ---'; cat /tmp/mdskill_trigger.log 2>/dev/null | head -20; echo '--- mdskill_trg.log ---'; cat /tmp/mdskill_trg.log 2>/dev/null | head -20"
done
