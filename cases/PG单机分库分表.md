# PG 单机分库分表（原生分区表）— PostgreSQL

> 可运行脚本：[../sql/partition_demo.sql](../sql/partition_demo.sql)
> 已在 GitHub Actions 的 PostgreSQL 16 中实际执行验证；脚本内嵌 `DO ... ASSERT` 断言，任一预期不符即让 CI 失败。

PostgreSQL 的“单机分库分表”：**分表**用声明式分区（10+ 引入），**分库**用 schema 做逻辑隔离。它解决的是单机“大表”问题，不具备跨机器水平扩展能力（那需要 Citus 或中间件）。

## 三种分区策略

| 策略 | 关键字 | 适用场景 |
| --- | --- | --- |
| Range | `PARTITION BY RANGE (col)` | 按时间/数值区间，最便于归档 |
| List | `PARTITION BY LIST (col)` | 按地区、状态等离散值 |
| Hash | `PARTITION BY HASH (col)` | 无明显分区键含义时均匀打散 |

## Range 分区（核心示例）

```sql
CREATE TABLE orders (
  id         BIGSERIAL,
  created_at timestamptz NOT NULL,
  amount     numeric(12, 2),
  PRIMARY KEY (id, created_at)   -- 分区键必须进主键
) PARTITION BY RANGE (created_at);

CREATE TABLE orders_2026_01 PARTITION OF orders
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');   -- 左闭右开
CREATE TABLE orders_default PARTITION OF orders DEFAULT;
```

## 验证点（脚本内已用断言覆盖）

- **自动路由**：向父表 `INSERT`，按分区键落到正确子分区；未命中范围的数据落 `DEFAULT` 分区。
- **分区裁剪**：`EXPLAIN` 带分区键的查询只扫描相关分区。
- **快速归档**：`ALTER TABLE orders DETACH PARTITION orders_2026_01;` 瞬间摘除整月数据。
- **逻辑分库**：`CREATE SCHEMA tenant_a;` 配合 `SET search_path` 切换租户。

## 关键差异点

- 分区表上的主键/唯一约束**必须包含分区键**，否则无法创建。
- 更新分区键值会触发行跨分区迁移，开销大，应保持分区键不变。
- 分区数量过多（上百个）会拉长规划时间，需结合时间粒度控制。
- 这些都是单机单实例内的能力，无法替代真正的分布式分片。
