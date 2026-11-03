#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0354
#   【TIMECHODB-0354】 【2051 rc2】windows环境 使用表模型示例数据 测试 LEFT JOIN 出现中文乱码 
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：中文不出现乱码  复现步骤 创建数据  create database database1;  use database1;  CREATE TABLE table1 (  time TIMESTAMP TIME,  r
# ============================================================================
RN0354_SQL=(
"create database database1"
"CREATE TABLE table1 (  time TIMESTAMP TIME,  region STRING TAG,  plant_id STRING TAG,  device_id STRING TAG,  model_id STRING ATTRIBUTE,  maintenance STRING ATTRIBUTE,  temperature FLOAT FIELD,  humidity FLOAT FIELD,  status Boolean FIELD,  arrival_time TIMESTAMP FIELD) WITH (TTL=31536000000)"
"CREATE TABLE table2 (  time TIMESTAMP TIME,  region STRING TAG,  plant_id STRING TAG,  device_id STRING TAG,  model_id STRING ATTRIBUTE,  maintenance STRING ATTRIBUTE,  temperature FLOAT FIELD,  humidity FLOAT FIELD,  status Boolean FIELD,  arrival_time TIMESTAMP FIELD) WITH (TTL=31536000000)"
"INSERT INTO table1(region, plant_id, device_id, model_id, maintenance, time, temperature, humidity, status, arrival_time) VALUES   ('北京', '1001', '100', 'A', '180', '2024-11-26 13:37:00', 90.0, 35.1, true, '2024-11-26 13:37:34'),  ('北京', '1001', '100', 'A', '180', '2024-11-26 13:38:00', 90.0, 35.1, true, '2024-11-26 13:38:25'),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:38:00', NULL, 35.1,  true, '2024-11-27 16:37:01'),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:39:00', 85.0, 35.3, NULL, Null),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:40:00', 85.0, NULL, NULL, '2024-11-27 16:37:03'),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:41:00', 85.0, NULL, NULL, '2024-11-27 16:37:04'),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:42:00', NULL, 35.2, false, Null),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:43:00', NULL, Null, false, Null),  ('北京', '1001', '101', 'B', '180', '2024-11-27 16:44:00', NULL, Null, false, '2024-11-27 16:37:08'),  ('上海', '3001', '100', 'C', '90', '2024-11-28 08:00:00', 85.0, Null, NULL, '2024-11-28 08:00:09'),  ('上海', '3001', '100', 'C', '90', '2024-11-28 09:00:00', NULL, 40.9, true, NULL),  ('上海', '3001', '100', 'C', '90', '2024-11-28 10:00:00', 85.0, 35.2, NULL, '2024-11-28 10:00:11'),  ('上海', '3001', '100', 'C', '90', '2024-11-28 11:00:00', 88.0, 45.1, true, '2024-11-28 11:00:12'),  ('上海', '3001', '101', 'D', '360', '2024-11-29 10:00:00', 85.0, NULL, NULL, '2024-11-29 10:00:13'),  ('上海', '3002', '100', 'E', '180', '2024-11-29 11:00:00', NULL, 45.1, true, NULL),  ('上海', '3002', '100', 'E', '180', '2024-11-29 18:30:00', 90.0, 35.4, true, '2024-11-29 18:30:15'),  ('上海', '3002', '101', 'F', '360', '2024-11-30 09:30:00', 90.0, 35.2, true, NULL),  ('上海', '3002', '101', 'F', '360', '2024-11-30 14:30:00', 90.0, 34.8, true, '2024-11-30 14:30:17')"
"INSERT INTO table2(region, plant_id, device_id, model_id, maintenance, time, temperature, humidity, status, arrival_time) VALUES   ('北京', '1001', '100', 'A', '180', '2024-11-26 13:37:00', 90.0, 35.1, true, '2024-11-26 13:37:34'),  ('北京', '1001', '101', 'B', '180', '2024-11-27 00:00:00', 85.0, 35.1,  true, '2024-11-27 16:37:01'),  ('上海', '3001', '100', 'C', '90', '2024-11-28 08:00:00', 85.0, 35.2, false, '2024-11-28 08:00:09'),  ('上海', '3001', '101', 'D', '360', '2024-11-29 00:00:00', 85.0, 35.1, NULL, '2024-11-29 10:00:13'),  ('上海', '3002', '100', 'E', '180', '2024-11-29 11:00:00', NULL, 45.1, true, NULL),  ('上海', '3002', '101', 'F', '360', '2024-11-30 00:00:00', 90.0, 35.2, true, NULL)"
"SELECT  region,  t1.time as time1,  t1.temperature as temperature1,   t2.time as time2,   t2.temperature as temperature2 FROM   table1 t1 LEFT JOIN table2 t2 USING(region) LIMIT 10"
)

case_RN0354() {
  local st out unexpected=0
  for st in "${RN0354_SQL[@]}"; do
    out=$( Q "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      unexpected=$((unexpected+1))
      fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"TIMECHODB-0354 自动抽取|TIMECHODB-0354|功能|2051 rc2】windows环境 使用表模型示例数据 测试 LEFT JOIN 出现中文乱码|case_RN0354"
)
