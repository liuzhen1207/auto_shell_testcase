#!/bin/bash
# 诊断：root.c33p 在 .77 上的文件布局与 .resource 内容
set -uo pipefail
D=/data/iotdb/v20121rc7_1014_7c61428
echo "=== find（-path 方式，与 cmp_lay 相同）==="
ssh -n root@192.168.99.77 "find $D/data/datanode/data -path '*/root.c33p/*' -type f -printf '%p\n' 2>/dev/null | sort" | sed "s|$D/data/datanode/data/||"
echo
echo "=== 直接 ls 目录树 ==="
ssh -n root@192.168.99.77 "ls -R $D/data/datanode/data/sequence/root.c33p 2>/dev/null | head -30"
echo
echo "=== 所有 .resource 文件（全库）==="
ssh -n root@192.168.99.77 "find $D/data/datanode/data -name '*.resource' 2>/dev/null | head -10"
echo
echo "=== root.c33p 的 resource 内容 ==="
F=$(ssh -n root@192.168.99.77 "find $D/data/datanode/data -path '*/root.c33p/*' -name '*.resource' 2>/dev/null | head -1")
echo "文件: $F"
[ -n "$F" ] && ssh -n root@192.168.99.77 "echo '--- cat ---'; cat '$F'; echo '--- cat -A（前 6 行）---'; head -6 '$F' | cat -A" | cut -c1-220
