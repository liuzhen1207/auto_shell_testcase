# 树转表视图的权限要求（实测：普通用户如何创建视图）

| 项目 | 内容 |
| --- | --- |
| 需求 | TDB-343 树转表视图自动扩列（需求文档 §3.3.3 访问控制：沿用原 `create view` 权限控制） |
| 验证版本 | 2.0.13.1 / `ab6d3de`，3C5D |
| 结论 | **`READ_SCHEMA` 可以授予**（属树模型权限，需在树路径上用树方言授权）；建视图需要「跨模型」三类权限，缺一不可 |
| 对应用例 | RN-181（无权限被拒）、RN-190（最小授权集合验证） |

---

## 一、结论：`READ_SCHEMA` 给得了

之前"表模型权限项里没有 READ_SCHEMA"的观察是对的，但结论错了：

- **`READ_SCHEMA` / `READ_DATA` 属于树模型权限**，只能用**树方言**在**树路径**上授予；
- **`CREATE` / `SELECT` 属于表模型权限**，用表方言在 database / table 上授予；
- 树转表视图跨两个模型：读树模型 schema + 在表模型建表，因此需要两类权限同时具备。

## 二、最小授权集合（实测可建视图并补列）

```sql
-- 前置
create database db1;                              -- 表模型库
create timeseries root.db1.dev01.s1 double;       -- 树模型测点
create user u1 'Pass@12345678';

-- ① 树模型：读 schema + 读数据（列类型推导需要）
grant read_schema on root.db1.** to user u1;
grant read_data   on root.db1.** to user u1;

-- ② 表模型：在目标库建表（视图也是表）
grant create on database db1 to user u1;

-- ③ 用 u1 建视图（表方言）
-- create view db1.v1(dev string tag) with(auto_sync_schema = true) as root.db1.**;
-- => 成功

-- ④ 查询该视图还需表模型 SELECT（按表授予）
grant select on table db1.v1 to user u1;
-- select * from db1.v1;  => 成功
```

## 三、权限缺口的错误提示是逐层暴露的

按"从少到多"授权，803 的提示会依次变化，可作为排障依据：

| 已授予 | 建视图时的返回 |
| --- | --- |
| 无 | `803: ... please add privilege READ_SCHEMA` |
| 树 `READ_SCHEMA`（授在 `root.db` 而非 `root.db.**`） | 仍报 `READ_SCHEMA`（**路径不匹配**） |
| 树 `READ_SCHEMA`（`root.db.**`） | `803: ... please add privilege CREATE ON db.v1` |
| 树 `READ_SCHEMA` + 表 `CREATE ON DATABASE` | `803: ... please add privilege READ_DATA` |
| 树 `READ_SCHEMA` + `READ_DATA` + 表 `CREATE` | **创建成功** |
| 创建成功后查询 | `803: ... please add privilege SELECT ON db.v1` |

两个容易踩的点：

1. **授权路径必须是 `root.db.**`**（视图的 prefixPath），只授 `root.db` 不够——视图要扫的是 prefix 下的所有测点；
2. **表模型 `CREATE` 授在 database 上就够**（`rn.db.*` 会覆盖到具体视图表名），不必预先授到 `db.v1` 这种还不存在的表名。

## 四、系统账号（root / sys_admin）为什么没这个问题

内置 `root` 与三个内置管理员（`sys_admin` / `security_admin` / `audit_admin`）持有全局权限，不受上述分层限制；本结论只影响**自建普通用户**。

## 五、建议补充到用户手册

> **创建树转表视图的权限要求**
> 使用普通用户创建树转表视图时，需要同时具备：
> - 树模型：`READ_SCHEMA`、`READ_DATA`（授予在视图的 prefixPath 上，如 `root.db1.**`）
> - 表模型：`CREATE`（授予在目标 database 上）
>
> 查询视图还需要表模型 `SELECT`（可授予在具体视图上）。

## 六、待确认（体验优化，非阻塞）

- 803 提示目前一次只报一个缺失权限（`READ_SCHEMA` → `CREATE` → `READ_DATA`），
  用户需要来回试 3 次才能凑齐；建议在提示中一次性列出建视图所需的完整权限清单。
