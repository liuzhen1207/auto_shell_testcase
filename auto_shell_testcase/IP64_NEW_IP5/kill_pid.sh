#!/bin/bash
exec 3<./datanode.txt
while read line <&3
do
	v_pid_str=`ssh liuzhen@${line} "sudo jps"|grep DataNode`
	v_pid=`echo $v_pid_str |awk '{print $1}'`
	echo "$v_pid"
	ssh liuzhen@${line} "sudo kill -9 ${v_pid}"
	
done
exec 3<./confignode.txt
while read line <&3
do
        v_pid_str=`ssh liuzhen@${line} "sudo jps"|grep ConfigNode`
        v_pid=`echo $v_pid_str |awk '{print $1}'`
        echo "$v_pid"
        ssh liuzhen@${line} "sudo kill -9 ${v_pid}"

done

# kill bm
jps|grep App|awk '{print "kill -9 "$1}'|sh
