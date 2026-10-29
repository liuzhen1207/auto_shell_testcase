#!/bin/bash
# 触发器全链路实验（完整输出，不截断）：
#   注册 -> SHOW -> 写入触发 -> 重启 -> SHOW -> 再写入 -> 触发? -> restore? -> DROP
cd /data/iotdb/autotest/metadata_skill || exit 1
. lib/common.sh
md_load_env
Q(){ timeout 120 "$CLI" -h "$QDN" -u "$DB_USER" -pw "$ROOT_PW" -timeout 60 -e "$1" 2>&1; }
JARURI="file:///data/iotdb/udf_md/mdskill.jar"
DB=root.md_trgf
T=r_f

fired(){  # 三节点 fire 总数
  local tot=0 c
  for h in "${DN[@]}"; do c=$(ssh -n -o BatchMode=yes root@$h "grep -c ' fire' /tmp/trgf.log 2>/dev/null" | tr -dc '0-9'); tot=$((tot+${c:-0})); done
  echo "$tot"
}
restored(){
  local tot=0 c
  for h in "${DN[@]}"; do c=$(ssh -n -o BatchMode=yes root@$h "grep -c ' restore' /tmp/trgf.log 2>/dev/null" | tr -dc '0-9'); tot=$((tot+${c:-0})); done
  echo "$tot"
}
pernode(){
  local per=""
  for h in "${DN[@]}"; do per="$per $h=$(ssh -n -o BatchMode=yes root@$h "grep -c ' fire' /tmp/trgf.log 2>/dev/null" | tr -dc '0-9')"; done
  echo "$per"
}

for h in "${DN[@]}"; do ssh -n -o BatchMode=yes root@$h "rm -f /tmp/trgf.log"; done
Q "DROP TRIGGER $T;"
Q "DROP DATABASE $DB;"
Q "CREATE DATABASE $DB;"
Q "CREATE TIMESERIES $DB.d1.s1 DOUBLE;"

echo "### 1) 注册 BEFORE INSERT ON $DB.d1.**"
Q "CREATE STATELESS TRIGGER $T BEFORE INSERT ON $DB.d1.** AS 'mdskill.MdTrigger' USING URI '$JARURI' WITH (marker='/tmp/trgf.log', tag='f1');"
Q "SHOW TRIGGERS;"
echo "### 2) 写入 -> fire"
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(1000, 1.0);"
sleep 5
echo "  fire 总数=$(fired)  明细:$(pernode)"
echo "### 3) 重启集群"
cluster_stop
cluster_start
echo "### 4) 重启后 SHOW TRIGGERS"
Q "SHOW TRIGGERS;"
echo "  restore 总数=$(restored)"
echo "### 5) 重启后写入 -> fire?"
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(2000, 2.0);"
sleep 6
echo "  fire 总数=$(fired)  明细:$(pernode)"
echo "### 6) marker 全文"
for h in "${DN[@]}"; do echo "  [$h] $(ssh -n -o BatchMode=yes root@$h "cat /tmp/trgf.log 2>/dev/null | sed -E 's/^[0-9]+ //' | tr '\n' '|'")"; done
echo "### 7) 再重启一次，看第二次是否恢复"
cluster_stop
cluster_start
Q "SHOW TRIGGERS;" | tail -4
Q "INSERT INTO $DB.d1(timestamp, s1) VALUES(3000, 3.0);"
sleep 6
echo "  fire 总数=$(fired)  restore 总数=$(restored)"
echo "### 8) DROP TRIGGER 后"
Q "DROP TRIGGER $T;"
Q "SHOW TRIGGERS;" | tail -4
Q "DROP DATABASE $DB;"
echo "### 9) 该次实验 DN 日志中的 trigger 关键字（.77）"
ssh -n -o BatchMode=yes root@192.168.99.77 "grep -iE 'trigger' $DB_DIR/logs/log_datanode_all.log | tail -15 | cut -c1-190"
