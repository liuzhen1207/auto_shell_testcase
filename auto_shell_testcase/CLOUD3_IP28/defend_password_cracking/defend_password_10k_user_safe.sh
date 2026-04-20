#!/bin/bash
current_dir=$(pwd)
db_dir=/home/cluster/v2091rc5_0417_089c5437/
cli_dir=/data/iotdb/v2091rc5_0417_089c5437/
ssl_str="-usessl true -ts ${cli_dir}/.truststore -tpw TimechoDB"
# db_ip os name os_name
os_name=root
db_admin_name=root
db_sec_name=security_admin
remote_cli_os_user=cluster
remote_cli_ip=172.20.70.13
db_ip=172.20.70.42
this_shell_ip=172.20.70.28
query_ip=${db_ip}
node_num=2
fail_flag=0
succ_flag=0
log_npe_flag=0
repeate_fail_flag=0
repeate_succ_flag=0
function create_10k_user()
{
>./create_10k_user.sql
for i in {1..10000}
do
echo "create user lily_${i} 'TimechoDB@2021';">>./create_10k_user.sql
done
   ${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e <./create_10k_user.sql
}
function drop_10k_user()
{
>./drop_10k_user.sql
for i in {1..10000}
do
echo "drop user lily_${i} ;">>./drop_10k_user.sql
done
${cli_dir}/sbin/start-cli.sh -u ${db_sec_name} -h ${query_ip} -sql_dialect table ${ssl_str} -e <./drop_10k_user.sql
}
# 并发数设置（同时处理10个用户）
CONCURRENT=10

# 总用户数
TOTAL_USERS=10000

# 并行处理函数
login_failed() {
  # 使用循环控制并发组，每组处理CONCURRENT个用户
  for ((group=0; group<TOTAL_USERS; group+=CONCURRENT)); do
    # 每组内启动CONCURRENT个进程并行执行
    for ((i=0; i<CONCURRENT; i++)); do
      # 计算当前用户编号（避免越界）
      user_num=$((group + i + 1))
      if ((user_num > TOTAL_USERS)); then
        break  # 超过总用户数则退出当前组循环
      fi
      
      # 并行执行登录命令（& 表示后台运行）
      (
        echo "Processing user lily_${user_num}"
        # 两次密码错误尝试
        ${cli_dir}/sbin/start-cli.sh -u lily_${user_num} -pw wrongpassword -h ${query_ip} -sql_dialect table ${ssl_str} -e "list privileges of user lily_${user_num};"
        ${cli_dir}/sbin/start-cli.sh -u lily_${user_num} -pw wrongpassword -h ${query_ip} -sql_dialect table ${ssl_str} -e "list privileges of user lily_${user_num};"
        # 一次正确密码尝试
        ${cli_dir}/sbin/start-cli.sh -u lily_${user_num} -pw TimechoDB@2021 -h ${query_ip} -sql_dialect table ${ssl_str} -e "list privileges of user lily_${user_num};"
      ) &
    done
    # 等待当前组的所有并发进程完成，再进入下一组
    wait
    echo "Completed group $((group/CONCURRENT + 1)) (users $((group + 1)) to $((group + CONCURRENT > TOTAL_USERS ? TOTAL_USERS : group + CONCURRENT)))"
  done
}
#while true
#do
create_10k_user
# 执行函数
login_failed
drop_10k_user
#done
