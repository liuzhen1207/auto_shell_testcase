#!/bin/bash
v_file=$1
if [ -z "$v_file" ]; then
    # 打印错误提示（>&2 表示将输出重定向到标准错误流，符合Shell规范）
    echo "input file name" >&2
    # 退出脚本并返回非0状态码（表示执行失败）
    exit 1
fi

sed -i 's/v_consensus=.*/v_consensus="IoTConsensusV2"/g' ${v_file}
sed -i 's/ioTConsensusServerImpl/PipeConsensusServerImpl/g' ${v_file}
sed -i 's/iot_consensus/pipe_consensus/g' ${v_file}
