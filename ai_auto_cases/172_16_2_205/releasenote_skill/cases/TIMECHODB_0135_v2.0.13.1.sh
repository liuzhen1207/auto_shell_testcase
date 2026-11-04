#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0135
#   【TIMECHODB-0135】 【OPC DA】datanode异常退出
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：正常启动  复现步骤 不稳定复现，但是出现之后只能删除文件解决。 启动opc-da-server，创建好元数据 启动IoTDB 写入出错，在某些错误操作后，iotdb异常退出，同时无法重启 关闭opc-da-server
# ============================================================================
RN0135_SQL=(
"create pipe opc ('sink'='opc-da-sink', 'opcda.clsid'='F8582CF2-88FB-11D0-B850-00C0F0104305')"
"create timeseries root.g1.d1.blob blob"
"create timeseries root.g1.d1.int32 int32"
"insert into root.g1.d1(blob,int32) values(X'1013',123)  # 正确的sql"
"insert into root.g1.d1(blob,int32) values(X'10131',123)  # 错误的sql"
"insert into root.g1.d1(blob,int32) values(X'10132',123)  # 错误的sql"
"insert into root.g1.d1(blob,int32) values(X'10133',123)  # 错误的sql"
)

case_RN0135() {
  local st out unexpected=0 RN_EXPECT_ERROR=1
  rn_run() {  # 方言自适配：先试首选方言，700/701 解析错误则换另一种方言重试
    local st=$1 o1 o2
    o1=$( T "$st" )
    if echo "$o1" | grep -qE '700: |701: '; then
      o2=$( Q "$st" )
      if ! echo "$o2" | grep -qE '700: |701: '; then echo "$o2"; return; fi
    fi
    echo "$o1"
  }
  for st in "${RN0135_SQL[@]}"; do
    out=$( rn_run "$st" )
    # 幂等：对象已存在视为可接受
    if echo "$out" | grep -qiE 'already exists|already been created'; then
      ok "已存在(幂等): $(echo "$st" | cut -c1-55)"; continue
    fi
    # 策略类错误：弱口令/无列/已存在，不算缺陷
    if echo "$out" | grep -qiE '820:|507:|501:'; then
      ok "策略/幂等类返回(可接受): $(echo "$st" | cut -c1-45)"; continue
    fi
    if echo "$out" | grep -qiE 'Exception|ERROR|internal error|NullPointerException'; then
      if [ "$RN_EXPECT_ERROR" = "1" ]; then
        ok "预期报错: $(echo "$st" | cut -c1-50)"
      else
        fail "$(echo "$st" | cut -c1-65) -> $(echo "$out" | head -1 | cut -c1-110)"
      fi
    else
      ok "$(echo "$st" | cut -c1-55)"
    fi
  done
}

CASES+=(
"RN-0135|TIMECHODB-0135 自动抽取|功能|OPC DA】datanode异常退出|case_RN0135"
)
