SET SQL_DIALECT=TABLE;
CREATE DATABASE del_rc10_obj002;
CREATE TABLE del_rc10_obj002.t (device_id STRING TAG, frame OBJECT FIELD, value INT32 FIELD);
INSERT INTO del_rc10_obj002.t(time,device_id,frame,value) VALUES (1792108800000,'d1',to_object(false,0,X'cafe'),10);
INSERT INTO del_rc10_obj002.t(time,device_id,frame,value) VALUES (1792108800000,'d1',to_object(true,2,X'babe'),11);
INSERT INTO del_rc10_obj002.t(time,device_id,frame,value) VALUES (1792108800001,'d2',to_object(true,0,X'deadbeef'),20);
FLUSH;

SET SQL_DIALECT=TABLE;
DELETE FROM del_rc10_obj002.t WHERE device_id='d1' AND time=1792108800000;

SET SQL_DIALECT=TABLE;
SELECT time,device_id,READ_OBJECT(frame),value FROM del_rc10_obj002.t ORDER BY time,device_id;

SET SQL_DIALECT=TABLE;
SELECT time,device_id,frame,value FROM del_rc10_obj002.t ORDER BY time,device_id;

