SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_cat002;
CREATE TABLE del_rc10_cat002.t (device_id STRING TAG, region STRING ATTRIBUTE, value INT32 FIELD);
INSERT INTO del_rc10_cat002.t(time,device_id,region,value) VALUES (1792022400000,'d1','north',10);
INSERT INTO del_rc10_cat002.t(time,device_id,region,value) VALUES (1792022400001,'d1','north',20);
INSERT INTO del_rc10_cat002.t(time,device_id,region,value) VALUES (1792022400000,'d2','north',30);
INSERT INTO del_rc10_cat002.t(time,device_id,region,value) VALUES (1792022400001,'d2','north',40);
INSERT INTO del_rc10_cat002.t(time,device_id,region,value) VALUES (1792022400000,'d3','south',50);
INSERT INTO del_rc10_cat002.t(time,device_id,region,value) VALUES (1792022400001,'d3','south',60);
FLUSH;
SELECT time,device_id,region,value FROM del_rc10_cat002.t ORDER BY time,device_id;
DELETE FROM del_rc10_cat002.t WHERE device_id='d1';
SELECT time,device_id,region,value FROM del_rc10_cat002.t ORDER BY time,device_id;
FLUSH;
SELECT time,device_id,region,value FROM del_rc10_cat002.t ORDER BY time,device_id;

