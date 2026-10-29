SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_flush001;
CREATE TABLE del_rc10_flush001.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_flush001.t(time,device_id,value) VALUES (1792600000000,'d1',0);
INSERT INTO del_rc10_flush001.t(time,device_id,value) VALUES (1792600000001,'d1',1);
INSERT INTO del_rc10_flush001.t(time,device_id,value) VALUES (1792600000002,'d1',2);
INSERT INTO del_rc10_flush001.t(time,device_id,value) VALUES (1792600000003,'d1',3);
INSERT INTO del_rc10_flush001.t(time,device_id,value) VALUES (1792600000004,'d1',4);
INSERT INTO del_rc10_flush001.t(time,device_id,value) VALUES (1792600000002,'d2',22);
FLUSH;
SELECT time,device_id,value FROM del_rc10_flush001.t ORDER BY time,device_id;

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_flush001.t WHERE device_id='d1' AND time >= 1792600000001 AND time <= 1792600000003;
SELECT time,device_id,value FROM del_rc10_flush001.t ORDER BY time,device_id;
SHOW REGIONS;

