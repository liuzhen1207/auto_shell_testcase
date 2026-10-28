v_test_time=`date +"%Y_%m_%d_%H_%M_%S"`
nohup env ENABLE_BACKUP_FAULT_DISK=1 BACKUP_FAULT_DELAY_SEC=600 sh -x ./tc2026_5c20d_1db_nottl_now_backup_last_reduce_clients_object_parallelism_default_disk_damanged.sh > ./${v_test_time}_v2_973_disk_damage.out 2>&1 < /dev/null & echo $!
