#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}

function reset_conf()
{

exec 3<${cur_dir}/../conf/confignode_1c.txt
while read line <&3
do
   if ssh ${os_user_name}@${line} test -d ${db_dir}/conf; then
      if ssh ${os_user_name}@${line} test -d ${db_dir}/conf_orig; then
         ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/conf"
         ssh ${os_user_name}@${line} "source /etc/profile;sudo cp -rp ${db_dir}/conf_orig ${db_dir}/conf"
      fi
   fi
done

exec 3<${cur_dir}/../conf/datanode_4d.txt
while read line <&3
do
   if ssh ${os_user_name}@${line} test -d ${db_dir}/conf; then
      if ssh ${os_user_name}@${line} test -d ${db_dir}/conf_orig; then
         ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/conf"
         ssh ${os_user_name}@${line} "source /etc/profile;sudo cp -rp ${db_dir}/conf_orig ${db_dir}/conf"
      fi
   fi
done

}
reset_conf
