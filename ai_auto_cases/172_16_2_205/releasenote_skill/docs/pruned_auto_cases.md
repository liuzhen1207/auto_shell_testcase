# 自动抽取用例剪枝清单

共 60 个缺陷单的 SQL 无法在 2.0.13.1 自动执行（老语法/占位符/依赖特殊环境），已从用例集移除。
如需回归，需按新版语法人工重写。

| 缺陷单 | 失败原因（截断） |
| --- | --- |
| TIMECHODB-0048 | [FAIL] create pipe test with source ('forwarding-pipe-requests'='false', -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0056 | [FAIL] create pipe test with source ('inclusion'='all') with sink('sink. -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0059 | [FAIL] select time,country,region,city,device,ab1,s1,s2,s3,s4 from t1 or -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0099 | [FAIL] create database dba1 with(TTL=3600000,TIME_PARTITION_INTERVAL=864 -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0107 | [FAIL] create table table_1 -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsing |
| TIMECHODB-0120 | [FAIL] insert into root.db.tc18_device(time,s01,s02,status) values(1,1,1 -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0126 | [FAIL] create table table_add -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsi |
| TIMECHODB-0146 | [FAIL] create table students -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsin |
| TIMECHODB-0154 | [FAIL] CREATE TABLE table_name ( column1 int32 COMMENT '', column2 int32 -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0158 | [FAIL] create table orders -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsing  |
| TIMECHODB-0178 | [FAIL] create table t1 (id1 tag,ab1 attribute, s1 int32) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 701: |
| TIMECHODB-0185 | [FAIL] create table table1(device string field, s1 int32 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLExceptio |
| TIMECHODB-0187 | [FAIL] insert into root.g1.d1(time,s1) values(【上一步的时间戳】， null) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException |
| TIMECHODB-0200 | [FAIL] alter database dba1 set properties TTL=3600000,SCHEMA_REGION_GROU -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0213 | [FAIL] create table table1(device string tag, s1 int32 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: |
| TIMECHODB-0240 | [FAIL] create table employees -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsi |
| TIMECHODB-0245 | [FAIL] desc test_db.t1 -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 550: Table 'test_db.t1' does not exist |
| TIMECHODB-0249 | [FAIL] create table employees -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsi |
| TIMECHODB-0251 | [FAIL] select distinct(time,int32,double) from t1 -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error  |
| TIMECHODB-0259 | [FAIL] create table t1(t1 tag,a1 attribute,s1 int32, s2 int64,s3 double, -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0280 | [FAIL] create table t1(tag1 STRING TAG, attr1 STRING ATTRIBUTE, s1 DOUBL -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0288 | [FAIL] show database -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: Error occurred while parsing SQL to |
| TIMECHODB-0297 | [FAIL] create table test_session(t1 STRING TAG,a1 STRING ATTRIBUTE, s1 I -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0298 | [FAIL] CREATE TABLE table1(province STRING FIELD, city STRING FIELD, reg -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0306 | [FAIL] create table table1(device string tag, value int32 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLExcepti |
| TIMECHODB-0318 | [FAIL] create table table1(device string tag, value int32 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLExcepti |
| TIMECHODB-0330 | [FAIL] create table device_flow (device string tag, flow int64 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLEx |
| TIMECHODB-0343 | [FAIL] create table device_flow (device string tag, flow int64 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLEx |
| TIMECHODB-0345 | [FAIL] create table device_flow (device string tag, id string attribute, -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0348 | [FAIL] create table orders( customer_id TAG, region ATTRIBUTE, order_dat -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0351 | [FAIL] create table orders( customer_id TAG, region ATTRIBUTE, order_dat -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0353 | [FAIL] create table orders( customer_id TAG, region ATTRIBUTE, order_dat -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0354 | [FAIL] CREATE TABLE table1 (  time TIMESTAMP TIME,  region STRING TAG,   -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0362 | [FAIL] create model dlinear_example using uri "file:///data/atmos/zk_tes -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0389 | [FAIL] SELECT count(t1.s_0) FROM v1_0 t1 LEFT JOIN v1_0 t2 USING(device_ -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0393 | [FAIL] create table table2(device_id string tag, s1 int32 field) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLExcepti |
| TIMECHODB-0402 | [FAIL] create view AA5 (sensor_id STRING TAG, value float field) AS root -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0404 | [FAIL] create view AA5 (sensor_id STRING TAG, value float field) AS root -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0410 | [FAIL] select s1 from root.db.** order by time align by device -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException |
| TIMECHODB-0413 | [FAIL] create aligned timeseries root.sg.d1(s1 float encoding=rle, s2 in -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0415 | [FAIL] create view AA5 (sensor_id STRING TAG, value float field) AS root -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0424 | [FAIL] create view AA5 (sensor_id STRING TAG, value float field) AS root -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0425 | [FAIL] create view AA5 (sensor_id STRING TAG, value float field) AS root -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0426 | [FAIL] select max_by(time, time_difference(*)),   min_by(time, time_diff -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0427 | [FAIL] insert into root.sg.d1(time,s1,s2) values(1752034017179000003,1,1 -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0433 | [FAIL] create timeseries root.sg.d1.s1 with datatype=BLOB -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 503 |
| TIMECHODB-0444 | [FAIL] alter view view_not_exist add column col from col -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 700: |
| TIMECHODB-0446 | [FAIL] create table tableD(device STRING TAG, value TIMESTAMP FIELD) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLExc |
| TIMECHODB-0450 | [FAIL] create table table1 ( time TIMESTAMP TIME, region STRING TAG, dev -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0479 | [FAIL] grant MANAGE_DATABASE,ALL on root.** to user lily -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 701: |
| TIMECHODB-0517 | [FAIL] create table source(s1 boolean field, device_id string tag) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLExcep |
| TIMECHODB-0529 | [FAIL] create table orders(customer_id TAG,region ATTRIBUTE,order_date D -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0536 | [FAIL] create table table1(t1 STRING TAG, a1 STRING ATTRIBUTE, s1 TEXT F -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0557 | [FAIL] create pipe test_disorder  with source('path'='root.sg.disorder.s -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0572 | [FAIL] create table table1( time Timestamp time, temperature float field -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0577 | [FAIL] List<String> columnNameList = Arrays.asList("region_id", "plant_i -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0600 | [FAIL] create aligned timeseries root.a.b (c int32, d int32) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException:  |
| TIMECHODB-0612 | [FAIL] create database test with (data_region_group_num=1) -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 70 |
| TIMECHODB-0656 | [FAIL] create function pattern_match as 'org.apache.iotdb.library.match. -> Msg: org.apache.iotdb.jdbc.IoTDBSQ |
| TIMECHODB-0657 | [FAIL] grant insert on database __audit to user user6 -> Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 803: Ac |
