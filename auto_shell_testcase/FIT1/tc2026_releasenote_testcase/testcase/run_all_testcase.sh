#!/bin/bash
desc=`cat ../conf/test.conf |grep "v_testdb="|awk -F '=' '{print $2}'`
mkdir ${desc}
i=1
v_cur_time=`date +'%Y_%m_%d_%H_%M_%S'`
exec 3<./testcase_ok_list.txt
while read line <&3
do
v_tc=`echo ${line}|awk -F '_' '{print $3}'`
   sh -x ${line} > ./${desc}/${v_tc}_res.out 2>&1
done
