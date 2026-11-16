SET SQL_DIALECT=TABLE;
CREATE DATABASE del_neg004;
CREATE TABLE del_neg004.t (dev STRING TAG, sensor STRING TAG, region STRING ATTRIBUTE, v INT32 FIELD);
INSERT INTO del_neg004.t(time,dev,sensor,region,v) VALUES (1796480000000,'dev01','s1','r1',10);
INSERT INTO del_neg004.t(time,dev,sensor,region,v) VALUES (1796480000001,'dev01','s1','r1',11);
FLUSH;
SELECT count(*) FROM del_neg004.t;