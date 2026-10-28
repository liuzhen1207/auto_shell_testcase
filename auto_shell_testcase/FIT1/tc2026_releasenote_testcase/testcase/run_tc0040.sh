#!/bin/bash
for i in {1..6}
do
	t=`date +%Y_%m_%d_%H_%M_%S`
	sh -x tc2026_April_0040_v2091_query_restart_dn_show_dev.sh > ${t}_${i}_tc0040.out 2>&1
	sleep 10
done
