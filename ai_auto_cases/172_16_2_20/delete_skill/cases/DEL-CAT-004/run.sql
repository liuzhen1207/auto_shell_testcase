SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_cat004;
CREATE TABLE del_rc10_cat004.t (device_id STRING TAG, region STRING ATTRIBUTE, value INT32 FIELD, aux INT32 FIELD);
INSERT INTO del_rc10_cat004.t(time,device_id,region,value,aux) VALUES (1792022400000,'d1','north',10,100);
INSERT INTO del_rc10_cat004.t(time,device_id,region,value,aux) VALUES (1792022400001,'d1','north',11,101);
INSERT INTO del_rc10_cat004.t(time,device_id,region,value,aux) VALUES (1792022400002,'d1','north',12,102);
INSERT INTO del_rc10_cat004.t(time,device_id,region,value,aux) VALUES (1792022400000,'d2','south',20,200);
INSERT INTO del_rc10_cat004.t(time,device_id,region,value,aux) VALUES (1792022400001,'d2','south',21,201);
INSERT INTO del_rc10_cat004.t(time,device_id,region,value,aux) VALUES (1792022400002,'d2','south',22,202);
FLUSH;
SELECT time,device_id,region,value,aux FROM del_rc10_cat004.t ORDER BY time,device_id;
DELETE FROM del_rc10_cat004.t WHERE value=11;
FLUSH;
SELECT time,device_id,region,value,aux FROM del_rc10_cat004.t ORDER BY time,device_id;

