#!/bin/bash
desc=v20101_rc3_0612_d9140d3
exec 3</data/testcase/conf/datanode.txt
while read line<&3
do
	v_ip=$(echo ${line}|awk -F '.' '{print $4}')
	mkdir -p ${desc}/dn_ip${v_ip}
	scp -rp  root@${line}:/data/iotdb/v20101_rc3_0612_d9140d3/logs/*all* ./${desc}/dn_ip${v_ip}
done
