#!/bin/bash
# 在三权分立模式下定位 OBS-10（授权不生效）与 OBS-11（UNLOCK 701）的原因
NEW=v20121rc12_1027_c05111d
CLI=/data2/iotdb/$NEW/sbin/start-cli.sh
R() { $CLI -h 172.16.2.2 -p 6667 -u root -pw 'TimechoDB@2021' -e "$1" 2>&1; }
S() { $CLI -h 172.16.2.2 -p 6667 -u security_admin -pw 'TimechoDB@2021' -e "$1" 2>&1; }
Y() { $CLI -h 172.16.2.2 -p 6667 -u sys_admin -pw 'TimechoDB@2021' -e "$1" 2>&1; }
U() { $CLI -h 172.16.2.2 -p 6667 -u probe_u -pw 'Probe@123456' -e "$1" 2>&1; }

echo "=== enable separation ==="
R "set configuration 'enable_separation_of_powers'='true'" | head -1
sleep 4
echo -n "root: "; R "show databases" | head -1

echo
echo "=== OBS-10: grant 变体对读的影响 ==="
Y "create database root.obs10" >/dev/null 2>&1
Y "create timeseries root.obs10.d1.s1 int32" >/dev/null 2>&1
Y "insert into root.obs10.d1(time,s1) values(1,42)" >/dev/null 2>&1
S "drop user probe_u" >/dev/null 2>&1
S "create user probe_u 'Probe@123456'" | head -1
echo -n "  no grant      -> "; U "select s1 from root.obs10.d1" | sed -n '2p'
S "grant read on root.obs10.** to user probe_u" | head -1
sleep 32
echo -n "  grant READ    -> "; U "select s1 from root.obs10.d1" | sed -n '2p'
echo "  list privileges (USER probe_u):"; S "list privileges of user probe_u" | head -6
S "grant read_schema on root.obs10.** to user probe_u" | head -1
sleep 32
echo -n "  +READ_SCHEMA  -> "; U "select s1 from root.obs10.d1" | sed -n '2p'
echo "  list privileges:"; S "list privileges of user probe_u" | head -8

echo
echo "=== OBS-11: UNLOCK 的几种写法 ==="
echo -n "  security_admin: ALTER USER probe_u ACCOUNT UNLOCK            -> "; S "alter user probe_u account unlock" | head -1
echo -n "  security_admin: ALTER USER probe_u@'172.16.2.205' UNLOCK     -> "; S "alter user probe_u@'172.16.2.205' account unlock" | head -1
echo -n "  sys_admin:      ALTER USER probe_u ACCOUNT UNLOCK            -> "; Y "alter user probe_u account unlock" | head -1
echo -n "  security_admin: ALTER USER security_admin ACCOUNT UNLOCK     -> "; S "alter user security_admin account unlock" | head -1

echo
echo "=== 清理 ==="
S "drop user probe_u" >/dev/null 2>&1
Y "drop database root.obs10" >/dev/null 2>&1
echo done
