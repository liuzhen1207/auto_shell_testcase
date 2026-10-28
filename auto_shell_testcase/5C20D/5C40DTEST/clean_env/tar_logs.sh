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
mkdir ${desc}
function clean_cluster()
{

exec 3<${cur_dir}/../conf/datanode_20d.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
	  v_ip=$(echo ${line}|awk -F '.' '{print $4}')
     ssh ${os_user_name}@${line} "source /etc/profile;tar czvf   ${db_dir}/dn_ip${v_ip}_logs.tar.gz ${db_dir}/logs/*datanode*all*"
     scp -rp ${os_user_name}@${line}:${db_dir}/dn_ip${v_ip}_logs.tar.gz ./${desc}
  fi

done

exec 3<${cur_dir}/../conf/confignode_6c.txt
while read line <&3
do
  if ssh ${os_user_name}@${line} test -d ${db_dir}/logs; then
	  v_ip=$(echo ${line}|awk -F '.' '{print $4}')
     ssh ${os_user_name}@${line} "source /etc/profile;tar -czvf  ${db_dir}/cn_ip${v_ip}_logs.tar.gz  ${db_dir}/logs/*confignode*all* "
     scp -rp ${os_user_name}@${line}:${db_dir}/cn_ip${v_ip}_logs.tar.gz ./${desc}
  fi

done

}
clean_cluster
