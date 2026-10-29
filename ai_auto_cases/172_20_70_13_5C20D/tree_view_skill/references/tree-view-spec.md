# 树转表视图：语法与语义速查

判定依据速查；权威来源：
- `/data/deepseek/skill_case/tree_view/树转表——需求分析（V2.0.5.1-开源）.docx`
- PLM doc 90（auto_sync_schema 需求）、doc 913（技术设计）、TDB-343

## 1. 创建

```sql
CREATE [OR REPLACE] VIEW view_name (col [dataType] TAG|TIME|FIELD [FROM m] [COMMENT '...'], ...)
  [COMMENT '...'] [RESTRICT] [WITH (ttl=..., auto_sync_schema=true|false)] AS 'root.db.**'
```

- `prefixPath` 必须以 `**` 结尾，其它层级不得出现 `*`/`**`；
- 列类别只有 TAG / FIELD / TIME，**没有 ATTRIBUTE**；
- 未声明 FIELD 列时，扫描 `prefixPath` 下全部测点自动生成列；
- 同名测点类型冲突、无任何测点 ⇒ 创建报错；
- `RESTRICT`：只匹配层级**严格等于** TAG 数量的设备；
- 视图 TTL 与树 TTL 取更小值，且不改变树模型设备 TTL。

## 2. auto_sync_schema（V2.0.13.1）

- 默认 false；`show create view` 可看到该属性；
- true 时：`create timeseries` / 对齐与多测点 / `insert` 自动建测点 / 模板激活与模板扩列
  都会触发视图**自动加列**；
- 只对树转表视图生效（base table、逻辑视图加该属性报错）；
- 新序列名小写与已有列冲突 → 不加列（记 warn，日志不暴露原序列名）；
- 新序列名已作为某列 `original_name` → 不加列，但查询仍可取到该列数据；
- 序列名含大写 → 列名转小写，原序列名记为 `original_name`；
- 与 `RESTRICT` 正交；
- `ALTER VIEW SET PROPERTIES auto_sync_schema=true/false`：false→true 需扫描合并
  （类型冲突则失败、属性保持 false）；true→false 直接关闭；
- 删除测点**不会**自动删列，该列查询为 null；
- 扩列是尽力而为：失败只记日志、不影响序列创建。

## 3. 查询语义差异

| 场景 | 树模型 | 表视图 |
|---|---|---|
| 对齐设备全 null 行 | 不保留 | **保留** |
| 非对齐设备全 null 行 | 不保留 | 不保留 |

## 4. 展示与 DDL

- `show tables details` 的 `TableType`：`BASE TABLE` / `VIEW FROM TREE` / `SYSTEM VIEW`；
- `show create view` 只接受 view；`show create table` 对 view/table 都可以；
- `ALTER VIEW` 支持 `RENAME TO` / `RENAME COLUMN` / `ADD COLUMN` / `DROP COLUMN` / `SET PROPERTIES`；
- `COMMENT ON VIEW` / `COMMENT ON COLUMN`。

## 5. 类型约束

树模型**不支持 OBJECT 类型测点**，因此树转表视图也不应出现 OBJECT 列；
`CREATE/ALTER VIEW ... OBJECT FIELD` 必须给出明确错误而不是静默成功。
