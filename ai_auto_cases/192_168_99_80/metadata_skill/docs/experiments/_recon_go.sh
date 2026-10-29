#!/bin/bash
# 在 99.80 上代为侦察集群节点
scp -q -o BatchMode=yes /tmp/_recon.sh root@192.168.99.77:/tmp/_recon.sh
ssh -n -o BatchMode=yes root@192.168.99.77 "bash /tmp/_recon.sh"
