# PLM 回归候选：缺陷描述摘录（用于写回归用例）

## TDB-442 删除后的数据在合并后重新出现

- 迭代：V2.0.12.1｜优先级：P0｜功能模块：存储-LSM 文件整理-在线文件合并
- 描述摘录（前 900 字）：iotdb 启动前设置： enable_seq_space_compaction=false enable_unseq_space_compaction=false enable_cross_space_compaction=false inner_compaction_candidate_file_num=2 compaction_schedule_interval_in_ms=1000 复现 SQL： CREATE DATABASE root.repro; CREATE TIMESERIES root.repro.s1 WITH DATATYPE=INT64; -- 第一个 TsFile：旧数据 INSERT INTO root.repro(time, s1) VALUES (1, 1); FLUSH; DELETE TIMESERIES root.repro.s1; CREATE TIMESERIES root.repro.s1 WITH DATATYPE=INT64; -- 第二个 TsFile：新数据 INSERT INTO root.repro(time, s1) VALUES (2, 2); FLUSH; -- 此时正确：只有 (2, 2) SELECT s1 FROM root.repro; SET CONFIGURATION 'enable_seq_space_compaction'='true'; -- IT 在这里等待 inner compaction 确实完成，再查询 SELECT s1 FROM root.repro; -- 当前返回两行 (1, 1)、(2, 2)，预期返回一行 (2, 2) 注意点： 必须保留两级 device root.repro；改成 root.repro.d1 就不触发这处缺陷。 应先确认合并完成

## TDB-352 【2.0.12.1】高频写入小 Object 时，删除旧 Object 开销过大导致写入较慢

- 迭代：V2.0.12.1｜优先级：P0｜功能模块：存储-CRUD操作-基础写入
- 描述摘录（前 900 字）：高频写入小 Object 时，删除旧 Object 开销过大导致写入较慢 复现步骤： 使用benchmark写入，报错：写入超时 system reject。 benchmark 配置： DB_SWITCH=IoTDB-200-SESSION_BY_TABLET USERNAME=root PASSWORD=TimechoDB@2021 IoTDB_DIALECT_MODE=table HOST=172.20.70.15 IS_DELETE_DATA=false LOOP=20000 DEVICE_NUMBER=10 SENSOR_NUMBER=100 IS_SENSOR_TS_ALIGNMENT=true GROUP_NAME_PREFIX=g_ IoTDB_TABLE_NAME_PREFIX=table_ DEVICE_NAME_PREFIX=d_ SENSOR_NAME_PREFIX=s_ IS_CLIENT_BIND=true SCHEMA_CLIENT_NUMBER=10 DATA_CLIENT_NUMBER=10 GROUP_NUMBER=1 IoTDB_TABLE_NUMBER=10 TEMPLATE=false TEMPLATE_NAME=BenchmarkTemplate VECTOR=true OP_MIN_INTERVAL=300 INSERT_DATATYPE_PROPORTION=1:1:1:41:50:1:1:1:1:1:1 BATCH_SIZE_PER_WRITE=1000 DEVICE_NUM_PER_WRITE=1 CREATE_SCHEMA=true START_TIME=2022-01-01T00:00:00+08:00 IS_OUT_OF_ORDER=false POINT_STEP=5000

## TDB-184 树模型的多设备超时的查询才会小概率触发，每次触发 reservedSize 就会增加一点，直到max capacity 就会导致后续查询报错

- 迭代：V1.3.8.1｜优先级：P0｜功能模块：None
- 描述摘录（前 900 字）：树模型的多设备超时的查询才会小概率触发，每次触发 reservedSize 就会增加一点，直到max capacity 就会导致后续查询报错

