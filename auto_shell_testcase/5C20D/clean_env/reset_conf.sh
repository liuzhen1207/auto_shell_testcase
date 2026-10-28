#!/bin/bash
# db_dir need exist and is your expect.
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
os_user_name=`cat ${conf_file}|grep ^os_user_name|awk -F '=' '{print $2}'`
testdb=`cat ${conf_file}|grep ^v_testdb|awk -F '=' '{print $2}'`
db_parent_dir=`cat ${conf_file}|grep ^v_db_parent_dir|awk -F '=' '{print $2}'`
cn_db_parent_dir=`cat ${conf_file}|grep ^v_cn_db_parent_dir|awk -F '=' '{print $2}'`
cli_dir=${db_parent_dir}/${testdb}
cn_db_dir=${cn_db_parent_dir}/${testdb}
dn_db_dir=${db_parent_dir}/${testdb}

function reset_conf()
{

exec 3<${cur_dir}/../conf/confignode_5c.txt
while read line <&3
do
   if ssh ${os_user_name}@${line} test -d ${cn_db_dir}/conf; then
      if ssh ${os_user_name}@${line} test -d ${cn_db_dir}/conf_orig; then
         ssh ${os_user_name}@${line} "source /etc/profile;rm -rf ${cn_db_dir}/conf"
         ssh ${os_user_name}@${line} "source /etc/profile;cp -rp ${cn_db_dir}/conf_orig ${cn_db_dir}/conf"
      fi
   fi
done

exec 3<${cur_dir}/../conf/datanode_20d.txt
while read line <&3
do
	v_exist=$(grep -x ${line} ${cur_dir}/../conf/confignode_5c.txt|wc -l)
	if [[ ${v_exist} = 0 ]];then

	   if ssh ${os_user_name}@${line} test -d ${dn_db_dir}/conf; then
	      if ssh ${os_user_name}@${line} test -d ${dn_db_dir}/conf_orig; then
		 ssh ${os_user_name}@${line} "source /etc/profile;rm -rf ${dn_db_dir}/conf"
		 ssh ${os_user_name}@${line} "source /etc/profile;cp -rp ${dn_db_dir}/conf_orig ${dn_db_dir}/conf"
	      fi
	   fi
	fi
done

}
reset_conf
