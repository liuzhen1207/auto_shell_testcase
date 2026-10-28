  #!/bin/bash

  if [ $# -ne 1 ]; then
      echo "用法：$0 <前缀参数>"
      echo "示例：$0 20260423"
      exit 1
  fi

  prefix=$1
  cur_dir="$(cd "$(dirname "$0")" && pwd)"

  cd "${cur_dir}" || exit 1

  rm -f "${prefix}_bm1.pid" "${prefix}_bm2.pid"
# set START_TIME=$(date +"%Y-%m-%dT%H:%M:%S%:z")
v_start_time=$(date +"%Y-%m-%dT%H:%M:%S%:z")
sed -i "s/START_TIME=.*/START_TIME=${v_start_time}/g" weather_now/conf_r*/config.properties
sleep 1
  echo "================ 启动 BM1 (weather_now/conf_rw) ================"
  nohup ./benchmark.sh -cf weather_now/conf_rw/ > "${prefix}_bm1.out" 2>&1 &
  bm1_pid=$!
  echo "${bm1_pid}" > "${prefix}_bm1.pid"
  echo "BM1 已后台启动，日志：${prefix}_bm1.out，PID：${bm1_pid}"

  echo "等待 30 分钟后启动 BM2..."
  sleep 1800

  echo "================ 启动 BM2 (weather_now/conf_rr) ================"
  nohup ./benchmark.sh -cf weather_now/conf_rr/ > "${prefix}_bm2.out" 2>&1 &
  bm2_pid=$!
  echo "${bm2_pid}" > "${prefix}_bm2.pid"
  echo "BM2 已后台启动，日志：${prefix}_bm2.out，PID：${bm2_pid}"

  echo "所有任务已提交完成！"
