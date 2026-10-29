SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_flush005;
CREATE TABLE del_rc10_flush005.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000000,'d1',0);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000001,'d1',1);
FLUSH;
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000002,'d1',2);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000003,'d1',3);
FLUSH;
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000004,'d1',4);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000005,'d1',5);
FLUSH;
SELECT time,device_id,value FROM del_rc10_flush005.t ORDER BY time,device_id;
DELETE FROM del_rc10_flush005.t WHERE device_id='d1' AND time >= 1793000000002 AND time <= 1793000000003;
SELECT time,device_id,value FROM del_rc10_flush005.t ORDER BY time,device_id;
SHOW REGIONS;

SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_flush005;
CREATE TABLE del_rc10_flush005.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000000,'d1',0);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000001,'d1',1);
FLUSH;
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000002,'d1',2);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000003,'d1',3);
FLUSH;
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000004,'d1',4);
INSERT INTO del_rc10_flush005.t(time,device_id,value) VALUES (1793000000005,'d1',5);
FLUSH;
SELECT time,device_id,value FROM del_rc10_flush005.t ORDER BY time,device_id;
SHOW REGIONS;

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_flush005.t WHERE device_id='d1' AND time >= 1793000000002 AND time <= 1793000000003;
SELECT time,device_id,value FROM del_rc10_flush005.t ORDER BY time,device_id;
SHOW REGIONS;

