#!/bin/bash
# ============================================================================
# 升级测试公共函数（releasenote_skill）
#   滚动升级 / 数据升级共用：
#     upg_stop_node <ip> <cn|dn>              停节点并等待进程退出
#     upg_swap_build <ip> <cn|dn> <old_build> <new_build>
#                                             就地替换 lib/sbin（旧目录备份为 lib_<old>、sbin_<old>）
#     upg_start_node <ip> <cn|dn> <dir>       启动节点并等待端口就绪
#     upg_wait_running <seconds>              等待集群 8/8
#     upg_restore_build <ip> <cn|dn> <old_build>
#                                             回滚（把 lib_<old> 换回）
# ============================================================================
UPG_CN_DIR=/data/iotdb
UPG_DN_DIR=/data1/iotdb
UPG_RC3=${UPG_RC3:-v20131rc3_1117_ac7f95e}
UPG_OLD=${UPG_OLD:-v20121rc12_1027_c05111d}

_upg_dir() {  # $1=cn|dn  $2=build
  if [ "$1" = "cn" ]; then echo "$UPG_CN_DIR/$2"; else echo "$UPG_DN_DIR/$2"; fi
}

upg_stop_node() {  # $1=ip $2=cn|dn
  local ip=$1 kind=$2 i
  ssh -n -o StrictHostKeyChecking=no root@$ip "pkill -9 -f '[c]om.timecho.iotdb' 2>/dev/null || true" 2>/dev/null
  for i in $(seq 1 30); do
    n=$(ssh -n -o StrictHostKeyChecking=no root@$ip "pgrep -cf '[c]om.timecho.iotdb' 2>/dev/null | head -1" 2>/dev/null | tr -dc '0-9')
    [ -z "${n:-}" ] && n=0
    [ "$n" = "0" ] && return 0
    sleep 2
  done
  return 1
}

upg_swap_build() {  # $1=ip $2=cn|dn $3=old_build $4=new_build
  local ip=$1 kind=$2 oldb=$3 newb=$4
  local olddir newdir
  olddir=$(_upg_dir "$kind" "$oldb")
  newdir=$(_upg_dir "$kind" "$newb")
  ssh -n -o StrictHostKeyChecking=no root@$ip "
    set -e
    cd '$olddir'
    rm -rf 'lib_$oldb' 'sbin_$oldb'
    [ -d lib ] && mv lib 'lib_$oldb'
    [ -d sbin ] && mv sbin 'sbin_$oldb'
    cp -a '$newdir/lib' lib
    cp -a '$newdir/sbin' sbin
    chmod +x sbin/*.sh 2>/dev/null || true
    ls -d lib sbin >/dev/null
  " 2>/dev/null
}

upg_restore_build() {  # $1=ip $2=cn|dn $3=old_build
  local ip=$1 kind=$2 oldb=$3
  local olddir; olddir=$(_upg_dir "$kind" "$oldb")
  ssh -n -o StrictHostKeyChecking=no root@$ip "
    cd '$olddir'
    rm -rf lib sbin
    [ -d 'lib_$oldb' ] && mv 'lib_$oldb' lib
    [ -d 'sbin_$oldb' ] && mv 'sbin_$oldb' sbin
    chmod +x sbin/*.sh 2>/dev/null || true
  " 2>/dev/null
}

upg_start_node() {  # $1=ip $2=cn|dn $3=dir
  local ip=$1 kind=$2 dir=$3 port
  local script
  if [ "$kind" = "cn" ]; then port=10710; script=start-confignode.sh; else port=10730; script=start-datanode.sh; fi
  ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd '$dir'; setsid '$dir/sbin/$script' > '$dir/start_${kind}.log' 2>&1 < /dev/null &" 2>/dev/null
  local i n
  for i in $(seq 1 60); do
    n=$(ssh -n -o StrictHostKeyChecking=no root@$ip "ss -lnt 2>/dev/null | grep -c ':$port'" 2>/dev/null)
    [ "${n:-0}" -ge 1 ] && return 0
    sleep 3
  done
  return 1
}

upg_wait_running() {  # $1=超时秒数
  local want=${1:-600} i n
  for i in $(seq 1 $((want / 5))); do
    n=$(T "show cluster" 2>/dev/null | grep -c Running)
    [ "${n:-0}" -ge 8 ] && return 0
    sleep 5
  done
  return 1
}

upg_version() {  # 输出当前集群 BuildInfo（取第一个 DataNode 行）
  T "show cluster" 2>/dev/null | awk -F'|' '/DataNode/{gsub(/ /,"",$8); print $8; exit}'
}
