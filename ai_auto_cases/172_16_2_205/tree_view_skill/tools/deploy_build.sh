#!/bin/bash
# Deploy a TimechoDB build onto the 3C5D cluster, keeping the cluster activation identity.
# usage: NEW=<build_dir> [PKG_ZIP=<zip>|PKG_DIR=<extracted>] [OLD_CN=.. OLD_DN=..] deploy_build.sh
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -f "$BASE/conf/env.conf" ] && . "$BASE/conf/env.conf"
NEW=${NEW:-master_1026_dc11a35}
OLD_CN=${OLD_CN:-/data/iotdb/v20121rc11_1023_ea4f835}
OLD_DN=${OLD_DN:-/data1/iotdb/v20121rc11_1023_ea4f835}
PKG=${PKG_DIR:-}
if [ -z "$PKG" ]; then
  if [ -n "${PKG_ZIP:-}" ] && [ -f "$PKG_ZIP" ]; then
    mkdir -p /data2/iotdb/$NEW/pkg
    unzip -q -o "$PKG_ZIP" -d /data2/iotdb/$NEW/pkg
    PKG=$(ls -d /data2/iotdb/$NEW/pkg/*-bin 2>/dev/null | head -1)
  else
    PKG=/data2/iotdb/$NEW/pkg/timechodb-2.0.11-SNAPSHOT-bin
  fi
fi
CN1=172.16.2.26
CN_LIST="172.16.2.26 172.16.2.27 172.16.2.28"
DN_LIST="172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6"
CLI=/data2/iotdb/$NEW
LOG=/tmp/deploy_$NEW.log
: > $LOG

die() { echo "FATAL: $*" | tee -a $LOG; exit 1; }
[ -d "$PKG/lib" ] || die "package missing: $PKG/lib"

gen_props() {
  local role=$1 ip=$2 cn_addr dn_addr dn_rpc
  if [ "$role" = "CN" ]; then cn_addr=$ip; dn_addr=127.0.0.1; dn_rpc=127.0.0.1
  else cn_addr=127.0.0.1; dn_addr=$ip; dn_rpc=$ip; fi
  cat <<EOF
cluster_name=TREEVIEW_1026
cn_seed_config_node=${CN1}:10710
dn_seed_config_node=${CN1}:10710
cn_internal_address=${cn_addr}
cn_internal_port=10710
cn_consensus_port=10720
dn_rpc_address=${dn_rpc}
dn_rpc_port=6667
dn_internal_address=${dn_addr}
dn_internal_port=10730
dn_mpp_data_exchange_port=10740
dn_schema_region_consensus_port=10750
dn_data_region_consensus_port=10760
schema_replication_factor=3
data_replication_factor=2
schema_region_consensus_protocol_class=org.apache.iotdb.consensus.ratis.RatisConsensus
data_region_consensus_protocol_class=org.apache.iotdb.consensus.iot.IoTConsensus
schema_region_group_extension_policy=AUTO
data_region_group_extension_policy=AUTO
default_schema_region_group_num_per_database=1
default_data_region_group_num_per_database=1
cn_metric_prometheus_reporter_port=9091
dn_metric_reporter_list=PROMETHEUS
dn_metric_prometheus_reporter_port=9092
enable_metric=true
EOF
}

echo "[$(date +%T)] stop old cluster" | tee -a $LOG
for ip in $CN_LIST; do ssh -o StrictHostKeyChecking=no root@$ip "bash $OLD_CN/sbin/stop-confignode.sh >/dev/null 2>&1; pkill -9 -f 'com.timecho.iotdb.ConfigNode'; true" 2>/dev/null; done
for ip in $DN_LIST; do ssh -o StrictHostKeyChecking=no root@$ip "bash $OLD_DN/sbin/stop-datanode.sh >/dev/null 2>&1; pkill -9 -f 'com.timecho.iotdb.DataNode'; true" 2>/dev/null; done
sleep 6

deploy_node() {
  local role=$1 ip=$2 old=$3 new=$4
  echo "================ $role $ip ================" | tee -a $LOG
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@$ip "test -d $old" || { echo "  ERROR old missing" | tee -a $LOG; return 1; }
  ssh -o StrictHostKeyChecking=no root@$ip "bash -s" <<EOS 2>&1 | tee -a $LOG
set -e
OLD=$old; NEW=$new
mkdir -p \$NEW
cd \$OLD
for f in *; do
  case "\$f" in data|logs) continue;; esac
  [ -e "\$NEW/\$f" ] || cp -a "\$f" "\$NEW/"
done
rm -rf \$NEW/lib \$NEW/sbin \$NEW/tools \$NEW/conf \$NEW/conf_orig \$NEW/data \$NEW/logs
echo "  skeleton ok, activation: \$(ls \$NEW/activation 2>/dev/null | tr '\n' ' ')"
EOS
  tar -C "$PKG" -cf - lib sbin tools conf 2>/dev/null | ssh -o StrictHostKeyChecking=no root@$ip "tar -C $new -xf -" || { echo "  ERROR tar" | tee -a $LOG; return 1; }
  gen_props $role $ip | ssh -o StrictHostKeyChecking=no root@$ip "cat > $new/conf/iotdb-system.properties"
  if [ "$role" = "CN" ]; then
    ssh -o StrictHostKeyChecking=no root@$ip "rm -f $new/conf/iotdb-cluster.properties; sed -i 's/^#*ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY=\"4G\"/' $new/conf/confignode-env.sh"
  else
    ssh -o StrictHostKeyChecking=no root@$ip "rm -f $new/conf/iotdb-cluster.properties; sed -i 's/^#*ON_HEAP_MEMORY=.*/ON_HEAP_MEMORY=\"8G\"/; s/^#*OFF_HEAP_MEMORY=.*/OFF_HEAP_MEMORY=\"4G\"/' $new/conf/datanode-env.sh"
  fi
  ssh -o StrictHostKeyChecking=no root@$ip "echo -n '  jars: '; ls $new/lib | wc -l; ls $new/lib | grep -i 'timechodb-server'; echo -n '  sbin: '; ls $new/sbin/*.sh | wc -l" | tee -a $LOG
}

for ip in $CN_LIST; do deploy_node CN $ip $OLD_CN /data/iotdb/$NEW; done
for ip in $DN_LIST; do deploy_node DN $ip $OLD_DN /data1/iotdb/$NEW; done

echo "=== client dir on 205 ===" | tee -a $LOG
rm -rf "$CLI/lib" "$CLI/sbin" "$CLI/tools" "$CLI/conf"
cp -a "$PKG"/. "$CLI"/
ls "$CLI/lib" | grep server
echo "[$(date +%T)] deploy done" | tee -a $LOG
