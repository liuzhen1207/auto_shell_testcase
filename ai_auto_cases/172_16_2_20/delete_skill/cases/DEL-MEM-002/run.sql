SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_mem002;
CREATE TABLE del_rc10_mem002.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_mem002.t(time,device_id,value) VALUES (1792500010000,'d1',0);
INSERT INTO del_rc10_mem002.t(time,device_id,value) VALUES (1792500010001,'d1',1);
INSERT INTO del_rc10_mem002.t(time,device_id,value) VALUES (1792500010002,'d1',2);
INSERT INTO del_rc10_mem002.t(time,device_id,value) VALUES (1792500010003,'d1',3);
INSERT INTO del_rc10_mem002.t(time,device_id,value) VALUES (1792500010004,'d1',4);

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_mem002.t WHERE time >= 1792500010001 AND time <= 1792500010003;

SET SQL_DIALECT=TABLE;
SELECT time,device_id,value FROM del_rc10_mem002.t ORDER BY time,device_id;

