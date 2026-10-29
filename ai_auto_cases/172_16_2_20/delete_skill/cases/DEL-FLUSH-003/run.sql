SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_flush003;
CREATE TABLE del_rc10_flush003.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000000,'d1',0);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000001,'d1',1);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000002,'d1',2);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000003,'d1',3);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000004,'d1',4);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000005,'d1',5);
INSERT INTO del_rc10_flush003.t(time,device_id,value) VALUES (1792800000004,'d2',22);
FLUSH;
SELECT time,device_id,value FROM del_rc10_flush003.t ORDER BY time,device_id;

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_flush003.t WHERE device_id='d1' AND time >= 1792800000003 AND time <= 1792800000005;
SELECT time,device_id,value FROM del_rc10_flush003.t ORDER BY time,device_id;
SHOW REGIONS;

