#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
cli_dir=${db_parent_dir}/${testdb}
db_dir=${db_parent_dir}/${testdb}


data1_dir="/data1/iotdb_data/${testdb}/data"
data3_dir="/data3/iotdb_data/${testdb}/data"

function clean_cluster()
{

exec 3<${cur_dir}/../conf/datanode_4d.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/data; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/data"
  fi
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/logs"
  fi
  if ssh ${os_user_name}@${line} test -d ${data1_dir}; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${data1_dir}"
  fi
  if ssh ${os_user_name}@${line} test -d ${data3_dir}; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${data3_dir}"
  fi

done

exec 3<${cur_dir}/../conf/confignode_3c.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/data; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/data"
  fi
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/logs"
  fi
  if ssh ${os_user_name}@${line} test -d ${data1_dir}; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${data1_dir}"
  fi
  if ssh ${os_user_name}@${line} test -d ${data3_dir}; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${data3_dir}"
  fi

done

exec 3<${cur_dir}/../conf/confignode_1c.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/data; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/data"
  fi
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${db_dir}/logs"
  fi
  if ssh ${os_user_name}@${line} test -d ${data1_dir}; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${data1_dir}"
  fi
  if ssh ${os_user_name}@${line} test -d ${data3_dir}; then
     ssh ${os_user_name}@${line} "source /etc/profile;sudo rm -rf ${data3_dir}"
  fi

done


}
clean_cluster
