#!/bin/bash
for i in {1..20}
do
sh -x kill_cn_dn.sh
sh -x rm_rf_iotdb_ip2_3_4.sh
sh -x scp_iotdb_ip2_3_4.sh
sleep 5
v_t=`date "+%Y_%m_%d_%H_%M_%S"`
sh -x tc2026_April_003604_upd_v2061_onebyoneNode_cn_first_seq_data_partitiontable_auto_repair_dev_ttl.sh > ./v2091rc3_cn_failed_request/${v_t}.out 2>&1 
done
