#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 ddl_ha_skill 的用例目录（spec.env / setup.sql / sql.sql / verify.sql）。

运行：python3 tools/gen_cases.py
用例矩阵见本文件 CASES；需求点映射见 README.md。
"""
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CASES_DIR = os.path.join(ROOT, "cases")

TABLE = "t"
VIEW = "v"


def dbname(case_id):
    return "ddlha_" + case_id.lower().replace("-", "_")


def setup_base(db, with_rows=False):
    s = [f"CREATE DATABASE {db};",
         f"CREATE TABLE {db}.{TABLE} (region STRING TAG, dev STRING TAG, s1 INT64 FIELD);"]
    if with_rows:
        for i, dev in enumerate(["dev01", "dev01", "dev02", "dev03"], start=1):
            s.append(f"INSERT INTO {db}.{TABLE}(time,region,dev,s1) VALUES ({i},'r1','{dev}',{i * 10});")
    return "\n".join(s)


def setup_base_s2(db):
    return setup_base(db, True) + f"\nALTER TABLE {db}.{TABLE} ADD COLUMN s2 INT32 FIELD;"


def setup_view(db):
    return setup_base(db, True) + f"\nCREATE WRITABLE VIEW {db}.{VIEW} AS SELECT s1 AS temp FROM {db}.{TABLE};"


def setup_ttl(db):
    return setup_base(db, True) + f"\nALTER TABLE {db}.{TABLE} SET PROPERTIES TTL=864000;"


def op_create_table(db):
    return (f"CREATE DATABASE {db};",
            f"CREATE TABLE {db}.{TABLE} (region STRING TAG, dev STRING TAG, s1 INT64 FIELD);",
            f"SELECT count(*) FROM {db}.{TABLE};", ("table_exists", TABLE), "meta+data")


def op_add_column(db):
    return (setup_base(db, True),
            f"ALTER TABLE {db}.{TABLE} ADD COLUMN s2 INT32 FIELD;",
            f"SELECT count(*) FROM {db}.{TABLE};", ("column_present", "s2"), "meta+data")


def op_alter_type(db):
    return (setup_base_s2(db),
            f"ALTER TABLE {db}.{TABLE} ALTER COLUMN s2 SET DATA TYPE INT64;",
            f"SELECT count(*) FROM {db}.{TABLE};", ("column_type", "s2:int64"), "meta+data")


def op_create_view(db):
    return (setup_base(db, True),
            f"CREATE WRITABLE VIEW {db}.{VIEW} AS SELECT s1 AS temp FROM {db}.{TABLE};",
            f"SELECT count(*) FROM {db}.{VIEW};", ("view_exists", VIEW), "meta")


def op_rename_view(db):
    return (setup_view(db),
            f"ALTER VIEW {db}.{VIEW} RENAME TO v2;",
            f"SELECT count(*) FROM {db}.v2;", ("view_exists", "v2"), "meta")


def op_set_ttl(db):
    return (setup_base(db, True),
            f"ALTER TABLE {db}.{TABLE} SET PROPERTIES TTL=864000;",
            f"SELECT count(*) FROM {db}.{TABLE};", ("ttl", "864000"), "meta+data")


def op_cancel_ttl(db):
    return (setup_ttl(db),
            f"ALTER TABLE {db}.{TABLE} SET PROPERTIES TTL='INF';",
            f"SELECT count(*) FROM {db}.{TABLE};", ("ttl", "INF"), "meta+data")


def op_drop_table(db):
    return (setup_base(db, True),
            f"DROP TABLE {db}.{TABLE};", "", ("table_absent", TABLE), "meta")


def op_drop_view(db):
    return (setup_view(db),
            f"DROP VIEW {db}.{VIEW};", "", ("view_absent", VIEW), "meta")


def op_drop_database(db):
    return (setup_base(db, True),
            f"DROP DATABASE {db};", "", ("db_absent", ""), "meta")


def op_delete_devices(db):
    return (setup_base(db, True),
            f"DELETE DEVICES FROM {db}.{TABLE} WHERE dev='dev02';",
            f"SELECT count(*) FROM {db}.{TABLE};", ("devices_deleted", "dev02"), "meta+data")


def op_insert_data(db):
    return (setup_base(db),
            f"INSERT INTO {db}.{TABLE}(time,region,dev,s1) VALUES (100,'r1','dev01',100);",
            f"SELECT count(*) FROM {db}.{TABLE};", ("table_exists", TABLE), "meta+data")


def op_create_table_restart(db):
    return (f"CREATE DATABASE {db};",
            f"CREATE TABLE {db}.{TABLE} (region STRING TAG, dev STRING TAG, s1 INT64 FIELD);",
            "", ("table_exists", TABLE), "meta")


def op_add_column_twice(db):
    return (setup_base(db, True),
            f"ALTER TABLE {db}.{TABLE} ADD COLUMN s2 INT32 FIELD;\n"
            f"ALTER TABLE {db}.{TABLE} ADD COLUMN s3 INT64 FIELD;",
            f"SELECT count(*) FROM {db}.{TABLE};", ("column_present", "s3"), "meta+data")


OPS = {
    "create_table": op_create_table,
    "add_column": op_add_column,
    "alter_type": op_alter_type,
    "create_view": op_create_view,
    "rename_view": op_rename_view,
    "set_ttl": op_set_ttl,
    "cancel_ttl": op_cancel_ttl,
    "drop_table": op_drop_table,
    "drop_view": op_drop_view,
    "drop_database": op_drop_database,
    "delete_devices": op_delete_devices,
    "insert_data": op_insert_data,
    "create_table_restart": op_create_table_restart,
    "add_column_twice": op_add_column_twice,
}

NORMAL_OPS = [
    ("001", "create_table"), ("002", "add_column"), ("003", "alter_type"),
    ("004", "create_view"), ("005", "rename_view"), ("006", "set_ttl"),
    ("007", "cancel_ttl"), ("008", "drop_table"), ("009", "drop_view"),
    ("010", "drop_database"), ("011", "delete_devices"),
]

DN_DOWN_OPS = [
    ("001", "create_table"), ("002", "add_column"), ("003", "alter_type"),
    ("004", "create_view"), ("005", "rename_view"), ("006", "set_ttl"),
    ("007", "drop_table"), ("008", "drop_database"), ("009", "delete_devices"),
]

PARTITION_OPS = [
    ("001", "create_table", "normal_dn", "success"),
    ("002", "add_column", "partitioned_dn", "fail_expected"),
    ("003", "insert_data", "partitioned_dn", "fail_expected"),
    ("004", "create_table", "normal_dn_heal", "success"),
]

EXTREME_OPS = [
    ("001", "drop_table", "dr_both_down", "fail_expected"),
    ("002", "delete_devices", "dr_both_down", "fail_expected"),
]

HA_OPS = [
    ("001", "add_column", "cn_leader_kill", "success"),
    ("002", "create_table_restart", "full_restart", "success"),
    ("003", "add_column_twice", "concurrent", "success"),
]

CASES = []
for cid, op in NORMAL_OPS:
    CASES.append(dict(case=f"DDLHA-N-{cid}", group="normal", op=op, fault="none",
                      target="19", timing="none", expect="success", sql_target="normal_dn"))
for cid, op in DN_DOWN_OPS:
    CASES.append(dict(case=f"DDLHA-D-{cid}", group="dn_down", op=op, fault="dn_kill",
                      target="auto_meta_replica", timing="before", expect="success",
                      sql_target="normal_dn"))
for cid, op, target, expect in PARTITION_OPS:
    CASES.append(dict(case=f"DDLHA-P-{cid}", group="partition", op=op, fault="dn_partition",
                      target="auto_meta_replica", timing="before", expect=expect,
                      sql_target=target))
for cid, op, fault, expect in EXTREME_OPS:
    CASES.append(dict(case=f"DDLHA-X-{cid}", group="extreme", op=op, fault=fault,
                      target="auto_dr_replicas", timing="before", expect=expect,
                      sql_target="normal_dn"))
for cid, op, fault, expect in HA_OPS:
    CASES.append(dict(case=f"DDLHA-C-{cid}", group="ha_event", op=op, fault=fault,
                      target="auto", timing="during", expect=expect,
                      sql_target="normal_dn"))


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text if text.endswith("\n") else text + "\n")


def main():
    if os.path.isdir(CASES_DIR):
        shutil.rmtree(CASES_DIR)
    os.makedirs(CASES_DIR)
    rows = []
    for c in CASES:
        cid = c["case"]
        db = dbname(cid)
        setup, sql, verify_sql, obj, kind = OPS[c["op"]](db)
        d = os.path.join(CASES_DIR, cid)
        os.makedirs(d)
        write(os.path.join(d, "setup.sql"), "SET SQL_DIALECT=TABLE;\n" + setup)
        write(os.path.join(d, "sql.sql"), "SET SQL_DIALECT=TABLE;\n" + sql)
        if verify_sql:
            write(os.path.join(d, "verify.sql"), "SET SQL_DIALECT=TABLE;\n" + verify_sql)
        spec = [
            f"CASE={cid}",
            f"GROUP={c['group']}",
            f"OP={c['op']}",
            f"DB={db}",
            f"TABLE={TABLE}",
            f"VIEW={VIEW}",
            f"FAULT={c['fault']}",
            f"FAULT_TARGET={c['target']}",
            f"TIMING={c['timing']}",
            f"EXPECT={c['expect']}",
            f"SQL_TARGET={c['sql_target']}",
            f"VERIFY_KIND={kind}",
            f"EXPECT_OBJECT={obj[0]}",
            f"EXPECT_VALUE={obj[1]}",
        ]
        write(os.path.join(d, "spec.env"), "\n".join(spec))
        rows.append("\t".join([cid, c["group"], c["op"], c["fault"], c["timing"],
                               c["expect"], obj[0], db]))

    write(os.path.join(ROOT, "cases.tsv"),
          "case_id\tgroup\top\tfault\ttiming\texpect\tverify\tdb\n" + "\n".join(rows))
    print(f"generated {len(rows)} cases -> {CASES_DIR}")


if __name__ == "__main__":
    main()
