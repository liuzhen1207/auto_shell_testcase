#!/bin/bash

# 检查是否传入参数
if [ $# -ne 1 ]; then
    echo "用法：$0 <前缀参数>"
    echo "示例：$0 20260423"
    exit 1
fi

prefix=$1
bm_dir="/benchmark/bm_20260423_obj_6d3310ad_v20"

cd ${bm_dir} || exit 1

echo "================ 启动 BM1 (weather/conf_rw) ================"
# 后台启动 BM1，输出到 ${prefix}_bm1.out
nohup ./benchmark.sh -cf weather/conf_rw/ > ${prefix}_bm1.out 2>&1 &
echo "BM1 已后台启动，日志：${prefix}_bm1.out"

# 等待 30 分钟（1800秒）
echo "等待 30 分钟后启动 BM2..."
sleep 1800

echo "================ 启动 BM2 (weather/conf_rr) ================"
# 后台启动 BM2，输出到 ${prefix}_bm2.out
nohup ./benchmark.sh -cf weather/conf_rr/ > ${prefix}_bm2.out 2>&1 &
echo "BM2 已后台启动，日志：${prefix}_bm2.out"

echo "所有任务已提交完成！"
