SET SQL_DIALECT=TABLE;
CREATE DATABASE del_dev009;
CREATE TABLE del_dev009.t (dev STRING TAG, sensor STRING TAG, region STRING ATTRIBUTE, v INT32 FIELD);
INSERT INTO del_dev009.t(time,dev,sensor,region,v) VALUES (1796470000000,'dev01','s1','r1',10);
INSERT INTO del_dev009.t(time,dev,sensor,region,v) VALUES (1796470000000,'dev02','s1','r1',20);
INSERT INTO del_dev009.t(time,dev,sensor,region,v) VALUES (1796470000000,'dev03','s1','r2',30);
FLUSH;
DELETE DEVICES FROM del_dev009.t WHERE region='r1' AND dev='dev01';
SELECT dev, region, count(*) FROM del_dev009.t GROUP BY dev, region ORDER BY dev;
