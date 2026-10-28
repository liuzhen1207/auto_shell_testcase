#!/bin/bash
#while true
#do
v_t1=$(date +%s)
desc=`cat ../conf/test.conf |grep "v_testdb="|awk -F '=' '{print $2}'`
mkdir ${desc}
i=1
v_cur_time=`date +'%Y_%m_%d_%H_%M_%S'`
exec 3<./testcase_ok_list.txt
while read line <&3
do
v_cur_time=`date +'%Y_%m_%d_%H_%M_%S'`
v_tc=`echo ${line}|awk -F '.' '{print $1}'`
   bash -x ${line} > ./${desc}/${v_tc}_res_${v_cur_time}.out 2>&1
done
#done
v_t2=$(date +%s)
v_elp=$((v_t2-v_t1))
echo "test time: ${v_elp} sec."
