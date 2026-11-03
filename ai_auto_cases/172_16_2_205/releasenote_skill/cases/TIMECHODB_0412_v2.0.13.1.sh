#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0412
#   【TIMECHODB-0412】 【树模型-SQL】普通用户拥有WRITE_DATA和WRITE_SCHEMA权限，创建view报305内部服务错误异常
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：普通用户拥有WRITE_DATA和WRITE_SCHEMA权限，database路径未被创建，进行创建视图返回正常提示  复现步骤 （1）启动1C1D  企业版：master分支 commitID：commit 3510
# ============================================================================
RN0412_SQL=(
"CREATE USER user01 'pass1234'"
"GRANT WRITE ON root.** TO USER user01"
"list privileges of user user01"
"CREATE ALIGNED TIMESERIES root.dacoo.deviceS12417( c0 INT32 encoding=PLAIN compressor=SNAPPY, c1 DOUBLE encoding=PLAIN compressor=SNAPPY, c2 INT32 encoding=PLAIN compressor=SNAPPY, c3 INT32 encoding=PLAIN compressor=SNAPPY, c4 BOOLEAN encoding=RLE compressor=SNAPPY, c5 FLOAT encoding=RLE compressor=SNAPPY,c6 FLOAT encoding=RLE compressor=SNAPPY,c11 INT32 encoding=PLAIN compressor=SNAPPY, c12 TEXT encoding=PLAIN compressor=SNAPPY )"
"insert into root.dacoo.deviceS12417(time,c0,c1,c2,c3,c4,c5,c6,c11,c12) values(1,1,2.2,1,1,true,1,1.2,1,\"hello1\")"
"insert into root.dacoo.deviceS12417(time,c0,c1,c2,c3,c4,c5,c6,c11,c12) values(2,2,22.2,21,21,false,2,2.2,2,\"hello2\")"
"insert into root.dacoo.deviceS12417(time,c0,c1,c2,c3,c4,c5,c6,c11,c12) values(2000,2000,202.2,201,201,false,203,203.2,203,\"hello3\")"
"insert into root.dacoo.deviceS12417(time,c0,c1,c2,c3,c4,c5,c6,c11,c12) values(129000,22000,3202.2,4201,51201,false,6203,7203.2,8203,\"hello-four\")"
)

case_RN0412() {
  local st out unexpected=0
  for st in "${RN0412_SQL[@]}"; do
    out=$( T "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      unexpected=$((unexpected+1))
      fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"TIMECHODB-0412 自动抽取|TIMECHODB-0412|功能|树模型-SQL】普通用户拥有WRITE_DATA和WRITE_SCHEMA权限，创建view报305内部服务错误异常|case_RN0412"
)
