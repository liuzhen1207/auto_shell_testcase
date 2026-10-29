SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_mem001;
CREATE TABLE del_rc10_mem001.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_mem001.t(time,device_id,value) VALUES (1792500000000,'d1',10);
INSERT INTO del_rc10_mem001.t(time,device_id,value) VALUES (1792500000001,'d1',11);
INSERT INTO del_rc10_mem001.t(time,device_id,value) VALUES (1792500000002,'d1',12);
INSERT INTO del_rc10_mem001.t(time,device_id,value) VALUES (1792500000001,'d2',21);

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_mem001.t WHERE time=1792500000001;

SET SQL_DIALECT=TABLE;
SELECT time,device_id,value FROM del_rc10_mem001.t ORDER BY time,device_id;

