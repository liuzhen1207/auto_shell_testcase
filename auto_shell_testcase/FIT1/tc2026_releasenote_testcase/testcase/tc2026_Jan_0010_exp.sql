DROP TABLE IF EXISTS "aa5";
CREATE VIEW "aa5" ("sensor_id" STRING TAG,"value" FLOAT FIELD) WITH (ttl=INF) AS root."reactor"."system1"."techSystem1"."DX"."HYH_W3"."AA5".**;
DROP TABLE IF EXISTS "tt5";
CREATE TABLE "tt5" ("sensor_id" STRING TAG,"value" FLOAT FIELD) WITH (ttl='INF');
DROP TABLE IF EXISTS "test";
CREATE TABLE "test" ("sensor_id" STRING TAG,"value1" INT64 FIELD,"first_t" TIMESTAMP FIELD,"last_t" TIMESTAMP FIELD,"last_v" FLOAT FIELD,"first_v" DOUBLE FIELD) WITH (ttl='INF');
DROP TABLE IF EXISTS "aa6";
CREATE VIEW "aa6" ("sensor_id" STRING TAG,"value" FLOAT FIELD) WITH (ttl=INF) AS root."reactor"."system1"."techSystem1"."DX"."HYH_W3"."AA5".**;
