SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_cat003;
CREATE TABLE del_rc10_cat003.t (device_id STRING TAG, region STRING ATTRIBUTE, value INT32 FIELD);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400000,'d1','north',10);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400001,'d1','north',11);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400002,'d1','north',12);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400000,'d2','north',20);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400001,'d2','north',21);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400002,'d2','north',22);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400000,'d3','south',30);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400001,'d3','south',31);
INSERT INTO del_rc10_cat003.t(time,device_id,region,value) VALUES (1792022400002,'d3','south',32);
FLUSH;
SELECT time,device_id,region,value FROM del_rc10_cat003.t ORDER BY time,device_id;

DELETE FROM del_rc10_cat003.t WHERE region='north' AND time >= 1792022400001 AND time <= 1792022400001;
SELECT time,device_id,region,value FROM del_rc10_cat003.t ORDER BY time,device_id;
FLUSH;
SELECT time,device_id,region,value FROM del_rc10_cat003.t ORDER BY time,device_id;

