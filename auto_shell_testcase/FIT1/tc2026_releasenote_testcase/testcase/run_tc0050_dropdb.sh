#!/bin/bash
while true
do
	v_bm_num=$(jps|grep App|wc -l)
	v_test_num=$(ps -ef|grep tc2026_V2_587_iotconsensus_delete_stop_dn_oom.sh|grep -v grep|wc -l)
	v_drop_db=$( /data2/v20111rc3_0724_5e2df19/sbin/start-cli.sh -h 192.168.130.2 -sql_dialect tree -timeout 3600 -e 'show migrations;'|grep DELETE|wc -l)
	v_total=$((v_bm_num+v_drop_db))
	if [[ ${v_total} = 0 ]];then
		break
	else
		sleep 600
	fi
done
v_cur_time=`date +'%Y_%m_%d_%H_%M_%S'`
bash -x tc2026_June_0050_remove_dn_obj_show_mig_no_ttl_multi_DRG.sh > tc2026_June_0050_remove_dn_obj_show_mig_no_ttl_multi_DRG_${v_cur_time}.out 2>&1 &
