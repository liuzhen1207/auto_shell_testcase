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

exec 3<${cur_dir}/../conf/datanode_20d.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
     ssh ${os_user_name}@${line} "source /etc/profile;mv ${db_dir}/logs ${db_dir}/logs_${desc}"
  fi

done

exec 3<${cur_dir}/../conf/confignode_5c.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
     ssh ${os_user_name}@${line} "source /etc/profile;mv ${db_dir}/logs ${db_dir}/logs_${desc}"
  fi

done

}
clean_cluster
