SET SQL_DIALECT=TABLE;
CREATE DATABASE del_dev007;
CREATE TABLE del_dev007.t (dev STRING TAG, sensor STRING TAG, region STRING ATTRIBUTE, v INT32 FIELD);
INSERT INTO del_dev007.t(time,dev,sensor,region,v) VALUES (1796460000000,'dev01','s1','r1',10);
INSERT INTO del_dev007.t(time,dev,sensor,region,v) VALUES (1796460000000,'dev02','s1','r1',20);
FLUSH;
SELECT dev, count(*) FROM del_dev007.t GROUP BY dev ORDER BY dev;