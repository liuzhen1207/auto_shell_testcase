SET SQL_DIALECT=TABLE;
CREATE DATABASE ddlha_ddlha_c_001;
CREATE TABLE ddlha_ddlha_c_001.t (region STRING TAG, dev STRING TAG, s1 INT64 FIELD);
INSERT INTO ddlha_ddlha_c_001.t(time,region,dev,s1) VALUES (1,'r1','dev01',10);
INSERT INTO ddlha_ddlha_c_001.t(time,region,dev,s1) VALUES (2,'r1','dev01',20);
INSERT INTO ddlha_ddlha_c_001.t(time,region,dev,s1) VALUES (3,'r1','dev02',30);
INSERT INTO ddlha_ddlha_c_001.t(time,region,dev,s1) VALUES (4,'r1','dev03',40);
