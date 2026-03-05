#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Please input new db info."
    exit
fi
cur_dir="$( cd "$( dirname "$0"  )" && pwd  )"
conf_file="${cur_dir}/../conf/test.conf"
new_db=$1
sed -i "s/^v_testdb.*/v_testdb=${new_db}/g" "${cur_dir}/../conf/test.conf"
new_commit=`echo "${new_db}"|rev|cut -c1-7|rev`
sed -i "s/^v_commit=.*/v_commit=${new_commit}/g" "${cur_dir}/../conf/test.conf"

