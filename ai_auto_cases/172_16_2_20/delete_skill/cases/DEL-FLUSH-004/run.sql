SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_flush004;
CREATE TABLE del_rc10_flush004.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_flush004.t(time,device_id,value) VALUES (1792900000000,'d1',0);
INSERT INTO del_rc10_flush004.t(time,device_id,value) VALUES (1792900000001,'d1',1);
INSERT INTO del_rc10_flush004.t(time,device_id,value) VALUES (1792900000002,'d1',2);
INSERT INTO del_rc10_flush004.t(time,device_id,value) VALUES (1792900000003,'d1',3);
INSERT INTO del_rc10_flush004.t(time,device_id,value) VALUES (1792900000004,'d1',4);
INSERT INTO del_rc10_flush004.t(time,device_id,value) VALUES (1792900000005,'d1',5);
FLUSH;
SELECT time,device_id,value FROM del_rc10_flush004.t ORDER BY time,device_id;

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_flush004.t WHERE device_id='d1' AND time >= 1792900000000 AND time <= 1792900000005;
SELECT time,device_id,value FROM del_rc10_flush004.t ORDER BY time,device_id;
SHOW REGIONS;

