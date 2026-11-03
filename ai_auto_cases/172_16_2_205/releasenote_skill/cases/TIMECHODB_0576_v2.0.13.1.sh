#!/bin/bash
# ============================================================================
# 来源缺陷单：TIMECHODB-0576
#   【TIMECHODB-0576】 【表模型】表名包含大于等于4个长度的中文，通过接口InsertTablet写入数据，此时写入不会报错，但表名会变成 【root."】
#   自动抽取用例（按缺陷单复现步骤顺序执行，断言无异常）
#   验证版本：2.0.13.1 / ab6d3de
#   预期摘要：表名包含大于等于4个长度的中文，通过接口InsertTablet写入数据，此时写入不会报错且表名显示正常  复现步骤 （1）启动1C1D （2）执行该程序  package org.apache.iotdb;  impo
# ============================================================================
RN0576_SQL=(
"List<String> columnNameList = Arrays.asList(\"region_id\", \"plant_id\", \"device_id\", \"model\", \"temperature\", \"humidity\")"
"List<TSDataType> dataTypeList = Arrays.asList( TSDataType.STRING, TSDataType.STRING, TSDataType.STRING, TSDataType.STRING, TSDataType.FLOAT, TSDataType.DOUBLE)"
"List<ColumnCategory> columnTypeList = new ArrayList<>( Arrays.asList( ColumnCategory.TAG, ColumnCategory.TAG, ColumnCategory.TAG, ColumnCategory.ATTRIBUTE, ColumnCategory.FIELD, ColumnCategory.FIELD))"
)

case_RN0576() {
  local st out unexpected=0
  for st in "${RN0576_SQL[@]}"; do
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
"TIMECHODB-0576 自动抽取|TIMECHODB-0576|功能|表模型】表名包含大于等于4个长度的中文，通过接口InsertTablet写入数据，此时写入不会报错，但表名会变成 【|case_RN0576"
)
