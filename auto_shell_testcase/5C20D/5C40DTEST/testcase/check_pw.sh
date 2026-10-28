db_dir=/data/iotdb/v20101_rc5_0618_c2d918b
for i in {100..119}
do
	ssh root@172.20.70.${i} "grep password ${db_dir}/logs/*all*"
done
