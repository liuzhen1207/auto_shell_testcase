SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_mem007;
CREATE TABLE del_rc10_mem007.t (device_id STRING TAG, value INT32 FIELD);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200000,'d1',0);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200001,'d1',1);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200002,'d1',2);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200003,'d1',3);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200004,'d1',4);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200005,'d1',5);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200006,'d1',6);
INSERT INTO del_rc10_mem007.t(time,device_id,value) VALUES (1792500200003,'d2',30);

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_mem007.t WHERE time >= 1792500200005 AND time <= 1792500200005;

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_mem007.t WHERE time >= 1792500200002 AND time <= 1792500200004;

