#!/bin/bash
# ============================================================================
# 来源缺陷单：【TIMECHODB-0423】普通用户拥有 WRITE_DATA + WRITE_SCHEMA 权限，
#   对尚未创建的 database 路径执行 CREATE VIEW，返回 305 内部服务错误
#   （Cannot invoke "java.util.List.iterator()" because "allPath" is null）
#   期望：返回正常的权限/路径提示（不是 305 内部错误）
#   验证版本：2.0.13.1 / ab6d3de
#   判据：①不是 305 ②给出可读的拒绝信息（权限/不存在）
# ============================================================================
RN0423_U=rn0423_u
RN0423_PW='Rn0423@123456'

case_RN110() {
  local out
  T "drop user $RN0423_U" >/dev/null 2>&1
  assert_ok "$(T "create user $RN0423_U '$RN0423_PW'")" "创建普通用户"
  assert_ok "$(T "grant write on root.** to user $RN0423_U")" "授予 WRITE（WRITE_DATA + WRITE_SCHEMA）"

  # root 先准备好"已存在的源序列"，保证列可解析；目标 view 所在 db 路径仍不存在
  T "create database root.rn0423src" >/dev/null 2>&1
  T "create timeseries root.rn0423src.d1.s1 int32" >/dev/null 2>&1
  T "insert into root.rn0423src.d1(time,s1) values(1,1)" >/dev/null 2>&1

  # 目标 database 路径 root.rn0423viewdb 不存在，普通用户创建 view
  out=$(L "$RN0423_U" "$RN0423_PW" "create view root.rn0423viewdb.v1 as select s1 from root.rn0423src.**")
  echo "  CREATE VIEW 返回：$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-220)"

  if echo "$out" | grep -q '305'; then
    fail "仍返回 305 内部服务错误（缺陷未修复）"
  else
    ok "不再返回 305 内部错误"
  fi
  if echo "$out" | grep -qi 'NullPointerException\|allPath'; then
    fail "返回内容暴露 NPE 细节"
  else
    ok "未暴露 NPE 细节"
  fi
  if echo "$out" | grep -qiE 'permission|privilege|权限|not exist|不存在|803|database'; then
    ok "给出可读的拒绝信息"
  else
    fail "拒绝信息不可读（实际 $(echo "$out" | head -1 | cut -c1-140)）"
  fi

  T "drop user $RN0423_U" >/dev/null 2>&1
}

CASES+=(
"RN-110|TIMECHODB-0423 视图权限|负向|普通用户对不存在的 db 路径建 view 不应返回 305 内部错误|case_RN110"
)
