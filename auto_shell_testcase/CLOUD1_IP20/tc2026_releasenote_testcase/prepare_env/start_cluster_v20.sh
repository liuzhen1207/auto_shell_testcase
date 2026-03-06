#!/bin/bash
# set -euo pipefail  # 开启严格模式，捕获未定义变量/命令失败

# ====================== 基础配置 ======================
cur_dir="$(cd "$(dirname "$0")" && pwd)"
conf_file="${cur_dir}/../conf/test.conf"
log_file="${cur_dir}/start_cluster_$(date +%Y%m%d_%H%M%S).log"

# 调试：打印脚本接收到的原始参数
echo "[$(date +%F_%T)] DEBUG: 脚本原始参数 - \$1=${1:-空}, \$2=${2:-空}" | tee -a "${log_file}"

# 读取配置文件（增加空值校验+容错）
os_user_name=$(grep "^os_user_name=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
testdb=$(grep "^v_testdb=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
db_parent_dir=$(grep "^v_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
shell_client_db_parent_dir=$(grep "^v_shell_client_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")
cn_db_parent_dir=$(grep "^v_cn_db_parent_dir=" "${conf_file}" 2>/dev/null | awk -F '=' '{gsub(/ /,""); print $2}' || echo "")

# 校验配置项非空
if [[ -z "${os_user_name}" || -z "${testdb}" || -z "${db_parent_dir}" || -z "${cn_db_parent_dir}" ]]; then
    echo "[$(date +%F_%T)] ERROR: 配置文件${conf_file}关键项为空！" | tee -a "${log_file}"
    exit 1
fi

# 定义路径（增加目录存在性校验）
cli_dir="${shell_client_db_parent_dir}/${testdb}"
db_dir="${db_parent_dir}/${testdb}"
cn_db_dir="${cn_db_parent_dir}/${testdb}"
license_dir="/ssd/license_20250619/"
v_start_time=$(date +%s)

# 读取外部参数（强制转为数字，避免字符串干扰）
cur_start_cluster_time=$(( ${1:-1} ))  # 参数1默认值1
total_node_num=$(( ${2:-6} ))          # 参数2默认值6

# 调试：打印参数赋值后的值
echo "[$(date +%F_%T)] DEBUG: 参数赋值后 - cur_start_cluster_time=${cur_start_cluster_time}, total_node_num=${total_node_num}" | tee -a "${log_file}"

# 读取查询节点IP（增加容错）
query_host=$(head -1 "${cur_dir}/../conf/datanode.txt" 2>/dev/null | sed 's/ //g' || echo "")
if [[ -z "${query_host}" ]]; then
    echo "[$(date +%F_%T)] ERROR: 未从datanode.txt读取到查询节点IP！" | tee -a "${log_file}"
    exit 1
fi

# ====================== 日志函数（增强版） ======================
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +%F_%T)
    echo "[${timestamp}] ${level}: ${msg}" | tee -a "${log_file}"
}

# ====================== 节点进程检查函数 ======================
check_node_process() {
    local node_ip=$1
    local node_type=$2  # CN/DN
    local process_keyword=$3  # confignode/datanode
    local ssh_user=$4

    # 检查进程是否存在
    local pid=$(ssh -o ConnectTimeout=5 "${ssh_user}@${node_ip}" "ps -ef | grep ${process_keyword} | grep -v grep | awk '{print \$2}'" 2>/dev/null || echo "")
    if [[ -n "${pid}" ]]; then
        log "INFO" "节点${node_ip} ${node_type}进程已启动，PID：${pid}"
        return 0
    else
        log "ERROR" "节点${node_ip} 未检测到${node_type}进程！"
        return 1
    fi
}

# ====================== 启动集群核心函数 ======================
start_cluster() {
    log "INFO" "==================== 集群启动开始 ===================="
    log "INFO" "启动参数：总节点数=${total_node_num}，查询节点=${query_host}，启动时间戳=${v_start_time}"

    # -------------------- 步骤1：启动ConfigNode --------------------
    cn_conf="${cur_dir}/../conf/confignode.txt"
    if [[ ! -f "${cn_conf}" ]]; then
        log "ERROR" "ConfigNode配置文件${cn_conf}不存在！"
        exit 1
    fi

    # 读取所有有效CN节点到数组
    cn_ips=()
    while read -r cn_ip; do
        cn_ip=$(echo "${cn_ip}" | sed 's/ //g')
        [[ -z "${cn_ip}" || "${cn_ip}" =~ ^# ]] && continue
        cn_ips+=("${cn_ip}")
    done < "${cn_conf}"

    # 检查CN节点数量
    cn_count=${#cn_ips[@]}
    if [[ ${cn_count} -eq 0 ]]; then
        log "ERROR" "未从${cn_conf}读取到有效ConfigNode节点！"
        exit 1
    fi
    log "INFO" "检测到${cn_count}个有效ConfigNode节点：${cn_ips[*]}"

    # 逐个启动CN节点
    for cn_ip in "${cn_ips[@]}"; do
        log "INFO" "-------------------- 处理ConfigNode节点：${cn_ip} --------------------"
        
        # 检查并拷贝license
        log "INFO" "节点${cn_ip} 检查license文件..."
        if ssh -o ConnectTimeout=5 "${os_user_name}@${cn_ip}" "test -f ${cn_db_dir}/activation/license" 2>/dev/null; then
            log "INFO" "节点${cn_ip} license已存在，拷贝.env文件"
            ssh "${os_user_name}@${cn_ip}" "mkdir -p ${cn_db_dir} && cp -rp ${cn_db_parent_dir}/.env ${cn_db_dir}/ || true"
        else
            if ssh -o ConnectTimeout=5 "${os_user_name}@${cn_ip}" "test -f ${cn_db_parent_dir}/timecho_license_new" 2>/dev/null; then
                log "INFO" "节点${cn_ip} 拷贝新license到激活目录"
                ssh "${os_user_name}@${cn_ip}" "mkdir -p ${cn_db_dir}/activation && cp -rp ${cn_db_parent_dir}/timecho_license_new ${cn_db_dir}/activation/license || true"
                ssh "${os_user_name}@${cn_ip}" "cp -rp ${cn_db_parent_dir}/.env ${cn_db_dir}/ || true"
            else
                log "WARN" "节点${cn_ip} 未找到license文件，继续启动"
            fi
        fi

        # 拼接并执行启动命令
        start_cn_cmd="source /etc/profile; nohup ${cn_db_dir}/sbin/start-confignode.sh -H ${cn_db_dir}/cn_${v_start_time}_heapdump.hprof > ${cn_db_dir}/start_cn_${v_start_time}.log 2>&1 &"
        log "INFO" "节点${cn_ip} 执行启动命令：ssh ${os_user_name}@${cn_ip} '${start_cn_cmd}'"

        ssh_exit_code=0
        ssh -o ConnectTimeout=10 "${os_user_name}@${cn_ip}" "${start_cn_cmd}" || ssh_exit_code=$?
        
        if [[ ${ssh_exit_code} -eq 0 ]]; then
            log "INFO" "节点${cn_ip} ConfigNode启动命令执行成功（退出码：${ssh_exit_code}）"
            sleep 2
            check_node_process "${cn_ip}" "ConfigNode" "confignode" "${os_user_name}"
        else
            log "ERROR" "节点${cn_ip} ConfigNode启动命令执行失败（退出码：${ssh_exit_code}）"
        fi
    done

    # -------------------- 步骤2：启动DataNode --------------------
    dn_conf="${cur_dir}/../conf/datanode.txt"
    if [[ ! -f "${dn_conf}" ]]; then
        log "ERROR" "DataNode配置文件${dn_conf}不存在！"
        exit 1
    fi

    # 读取所有有效DN节点到数组
    dn_ips=()
    while read -r dn_ip; do
        dn_ip=$(echo "${dn_ip}" | sed 's/ //g')
        [[ -z "${dn_ip}" || "${dn_ip}" =~ ^# ]] && continue
        dn_ips+=("${dn_ip}")
    done < "${dn_conf}"

    # 检查DN节点数量
    dn_count=${#dn_ips[@]}
    if [[ ${dn_count} -eq 0 ]]; then
        log "ERROR" "未从${dn_conf}读取到有效DataNode节点！"
        exit 1
    fi
    log "INFO" "检测到${dn_count}个有效DataNode节点：${dn_ips[*]}"

    # 逐个启动DN节点
    for dn_ip in "${dn_ips[@]}"; do
        log "INFO" "-------------------- 处理DataNode节点：${dn_ip} --------------------"
        
        # 拼接并执行启动命令
        start_dn_cmd="source /etc/profile; nohup ${db_dir}/sbin/start-datanode.sh -H ${db_dir}/dn_${v_start_time}_heapdump.hprof > ${db_dir}/start_dn_${v_start_time}.log 2>&1 &"
        log "INFO" "节点${dn_ip} 执行启动命令：ssh ${os_user_name}@${dn_ip} '${start_dn_cmd}'"

        ssh_exit_code=0
        ssh -o ConnectTimeout=10 "${os_user_name}@${dn_ip}" "${start_dn_cmd}" || ssh_exit_code=$?
        
        if [[ ${ssh_exit_code} -eq 0 ]]; then
            log "INFO" "节点${dn_ip} DataNode启动命令执行成功（退出码：${ssh_exit_code}）"
            sleep 2
            check_node_process "${dn_ip}" "DataNode" "datanode" "${os_user_name}"
        else
            log "ERROR" "节点${dn_ip} DataNode启动命令执行失败（退出码：${ssh_exit_code}）"
        fi
    done
# -------------------- 步骤3：等待集群就绪（解决v_ok_num未执行问题） --------------------
log "INFO" "==================== 等待集群状态达标 ===================="
log "INFO" "目标就绪节点数：${total_node_num}，最大等待时间：300秒"

local wait_count=0
local max_wait=300
local cluster_ready=0
local v_ok_num=0
local cli_retry=0  # CLI重试次数

while [[ ${wait_count} -lt ${max_wait} ]]; do
    # 重置统计值，避免上次循环的残留
    v_ok_num=0
    v_running=0
    v_readonly=0

    # 执行show cluster（增加3次重试，避免临时网络问题）
    cluster_status=""
    cli_retry=0
    while [[ ${cli_retry} -lt 3 && -z "${cluster_status}" ]]; do
        cluster_status=$("${cli_dir}/sbin/start-cli.sh" -h "${query_host}" -e "show cluster;" 2>/dev/null || echo "")
        cli_retry=$((cli_retry + 1))
        sleep 1  # 重试间隔1秒
    done

    # 处理空值/连接错误（但不再直接continue，而是标记为0）
    if [[ -z "${cluster_status}" || "${cluster_status}" =~ becauseConnection\ Error ]]; then
        log "WARN" "第${wait_count}秒：CLI执行失败（重试${cli_retry}次），错误信息：${cluster_status}"
        v_ok_num=0  # 强制设置为0，避免未定义
    else
        # 精准统计：只统计实际节点行的Running/ReadOnly状态
        v_running=$(echo "${cluster_status}" | grep -E "ConfigNode|DataNode" | grep -c "Running")
        v_readonly=$(echo "${cluster_status}" | grep -E "ConfigNode|DataNode" | grep -c "ReadOnly")
        v_ok_num=$((v_running + v_readonly))
    fi

    # 调试：无论是否失败，都打印统计信息（关键！）
    log "DEBUG" "统计详情 - total_node_num=${total_node_num}, v_running=${v_running}, v_readonly=${v_readonly}, v_ok_num=${v_ok_num}"
    log "INFO" "第${wait_count}秒：当前就绪节点数=${v_ok_num}/${total_node_num}（Running:${v_running}, ReadOnly:${v_readonly}）"
    
    # 核心判定：一旦满足条件立即跳出循环
    if [[ ${v_ok_num} -eq ${total_node_num} ]]; then
        log "INFO" "✅ 集群所有节点已就绪！"
        cluster_ready=1
        break
    fi

    wait_count=$((wait_count + 1))
    sleep 1
done

# 最终状态判断
if [[ ${cluster_ready} -eq 1 ]]; then
    log "INFO" "==================== 集群启动成功 ===================="
    log "INFO" "📝 日志文件：${log_file}"
    log "INFO" "📌 CN启动日志：各节点${cn_db_dir}/start_cn_${v_start_time}.log"
    log "INFO" "📌 DN启动日志：各节点${db_dir}/start_dn_${v_start_time}.log"
    return 0
else
    log "ERROR" "==================== 集群启动超时 ===================="
    log "ERROR" "❌ 等待${max_wait}秒后集群仍未就绪，最终就绪数=${v_ok_num}/${total_node_num}"
    exit 1
fi

}

# ====================== 执行主函数 ======================
start_cluster

# ====================== 脚本结束 ======================
log "INFO" "集群启动脚本执行完成，完整日志路径：${log_file}"
exit 0
