#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0577
#   【TIMECHODB-0577】 【表模型】表名含有中文长度为2个字符时，通过接口InsertTablet接口写入异常，提示"XX" is not a legal path
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：表模型】表名含有中文长度为2个字符时，通过接口InsertTablet接口写入正常 复现步骤 （1）启动1C1D （2）通过程序写入数据   package org.apache.iotdb;  import org.a
# ============================================================================
RN0577_SQL=(
"List<String> columnNameList = Arrays.asList(\"region_id\", \"plant_id\", \"device_id\", \"model\", \"temperature\", \"humidity\")"
"List<TSDataType> dataTypeList = Arrays.asList( TSDataType.STRING, TSDataType.STRING, TSDataType.STRING, TSDataType.STRING, TSDataType.FLOAT, TSDataType.DOUBLE)"
"List<ColumnCategory> columnTypeList = new ArrayList<>( Arrays.asList( ColumnCategory.TAG, ColumnCategory.TAG, ColumnCategory.TAG, ColumnCategory.ATTRIBUTE, ColumnCategory.FIELD, ColumnCategory.FIELD))"
)

case_RN0577() {
  local st out unexpected=0
  for st in "${RN0577_SQL[@]}"; do
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
"TIMECHODB-0577 自动抽取|TIMECHODB-0577|功能|表模型】表名含有中文长度为2个字符时，通过接口InsertTablet接口写入异常，提示"XX" is not a |case_RN0577"
)
