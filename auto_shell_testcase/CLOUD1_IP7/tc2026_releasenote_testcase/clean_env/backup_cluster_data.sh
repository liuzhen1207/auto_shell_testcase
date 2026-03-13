#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}

desc=$1
function clean_cluster()
{

exec 3<${cur_dir}/../conf/datanode.txt
while read line <&3
do
v_ip=`echo ${line}|awk -F '.' '{print $4}'`
mkdir /data2/auto_test/cluster_shell_3c5d_no2/tc2026_releasenote_testcase/testdata_backup/ip${v_ip}
scp -rp ${os_user_name}@${line}:${db_parent_dir}/testdata_backup/${testdb} /data2/auto_test/cluster_shell_3c5d_no2/tc2026_releasenote_testcase/testdata_backup/ip${v_ip}

#     ssh ${os_user_name}@${line} "source /etc/profile;mkdir -p ${db_parent_dir}/testdata_backup/${testdb}"
#     ssh ${os_user_name}@${line} "source /etc/profile;cp -rp ${db_dir}/data ${db_parent_dir}/testdata_backup/${testdb}"
#     ssh ${os_user_name}@${line} "source /etc/profile;cp -rp ${db_dir}/logs ${db_parent_dir}/testdata_backup/${testdb}"

done

exec 3<${cur_dir}/../conf/confignode.txt
while read line <&3
do
v_ip=`echo ${line}|awk -F '.' '{print $4}'`
mkdir /data2/auto_test/cluster_shell_3c5d_no2/tc2026_releasenote_testcase/testdata_backup/ip${v_ip}
scp -rp ${os_user_name}@${line}:${db_parent_dir}/testdata_backup/${testdb} /data2/auto_test/cluster_shell_3c5d_no2/tc2026_releasenote_testcase/testdata_backup/ip${v_ip}
#     ssh ${os_user_name}@${line} "source /etc/profile;mkdir -p ${db_parent_dir}/testdata_backup/${testdb}"
#     ssh ${os_user_name}@${line} "source /etc/profile;cp -rp ${db_dir}/logs ${db_parent_dir}/testdata_backup/${testdb}"
#     ssh ${os_user_name}@${line} "source /etc/profile;cp -rp ${db_dir}/data ${db_parent_dir}/testdata_backup/${testdb}"

done

}
clean_cluster
