是的，PostgreSQL **自带原生分区表功能**。你之前提到的“原生分库分表”指的是跨机器的分布式分片，而 PostgreSQL 的原生分区是**单机内**的表拆分能力，两者需要区分开。

### 原生分区：从哪个版本开始？
PostgreSQL 从 **10.0 版本**开始引入了声明式分区（Declarative Partitioning），这就是官方所说的“原生分区”。在此之前，实现分区需要依赖触发器或继承等相对繁琐的方式。

### 它具体能做什么？
你可以直接在创建表时指定分区策略，支持 **Range（范围）、List（列表）、Hash（哈希）** 三种方式。
*   **自动路由**：向父表插入数据时，数据库会根据分区键自动将数据放入对应的子分区，应用层无需关心具体落在哪个物理表。
*   **分区裁剪**：查询时，优化器会分析 `WHERE` 条件，自动跳过不相关的分区，只扫描需要的数据，从而提升查询性能。
*   **快速维护**：对于按时间分区的归档场景，删除旧数据时可以直接 `DROP` 或 `DETACH` 整个分区，这比逐行 `DELETE` 要快得多，对系统影响也小。

### 关键限制：它是单机的
需要特别注意，PostgreSQL 的原生分区**只解决了单台服务器内部的“大表”问题**，它并不具备跨多台机器水平扩展（分库分表）的能力。如果你的单机容量或写入性能达到瓶颈，仍然需要借助 **Citus** 这类扩展，或者外部的中间件来实现真正的分布式分片。

所以，如果你的归档场景只是单表数据量大，用 PG 原生分区就能很好地管理；但如果数据量已经大到单机磁盘装不下或单机写入扛不住，那它就不能直接替代你之前看的 TiDB/OceanBase 那类分布式数据库了。

---

## PG 单机分库分表（原生分区表）实战

> 完整可运行示例见 [sql/partition_demo.sql](sql/partition_demo.sql)（内嵌断言，已在 GitHub Actions 的 PostgreSQL 16 实际执行），案例说明见 [cases/PG单机分库分表.md](cases/PG单机分库分表.md)。

> 单机场景下，“分表”用**声明式分区（Declarative Partitioning）**实现；“分库”一般用 **schema** 在同一实例内做逻辑隔离。下面示例基于 PostgreSQL 16，语法在 10+ 通用。

### 1. Range 分区（最常用：按时间拆分）

按月份把订单表拆成多个子分区，天然适配归档场景。

```sql
-- 父表：分区键必须包含在主键/唯一约束中
CREATE TABLE orders (
    id         BIGSERIAL,
    created_at timestamptz NOT NULL,
    amount     numeric(12, 2),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- 子分区：左闭右开区间
CREATE TABLE orders_2026_01 PARTITION OF orders
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE orders_2026_02 PARTITION OF orders
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

-- 兜底分区：未命中任何区间的数据落到这里
CREATE TABLE orders_default PARTITION OF orders DEFAULT;
```

### 2. List 分区（按地区/状态等离散值）

```sql
CREATE TABLE sales_by_region (
    id     BIGSERIAL,
    region text NOT NULL,
    amount numeric(12, 2),
    PRIMARY KEY (id, region)
) PARTITION BY LIST (region);

CREATE TABLE sales_east PARTITION OF sales_by_region
    FOR VALUES IN ('east', 'northeast');
CREATE TABLE sales_west PARTITION OF sales_by_region
    FOR VALUES IN ('west', 'southwest');
```

### 3. Hash 分区（数据均匀分布，无明确分区键业务含义时）

```sql
CREATE TABLE users (
    id   bigint NOT NULL,
    name text,
    PRIMARY KEY (id)
) PARTITION BY HASH (id);

-- MODULUS 为分区数，REMAINDER 为余数（0 ~ MODULUS-1）
CREATE TABLE users_p0 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE users_p1 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE users_p2 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE users_p3 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

### 4. 自动路由与分区裁剪

向父表 `INSERT`，数据库按分区键自动落到对应子分区，应用无感知：

```sql
INSERT INTO orders (created_at, amount)
VALUES ('2026-01-15', 99.5), ('2026-02-20', 128.0);

-- 查询时带分区键条件，优化器只扫描相关分区
EXPLAIN (COSTS OFF)
SELECT * FROM orders
WHERE created_at >= '2026-01-01' AND created_at < '2026-02-01';
```

### 5. 快速归档：DETACH 分区

历史数据归档时无需逐行 `DELETE`，直接 `DETACH` 整个分区，几乎瞬间完成：

```sql
ALTER TABLE orders DETACH PARTITION orders_2026_01;
-- 之后可直接对独立出来的表做备份、转储或 DROP
```

### 6. “分库”：同实例内用 schema 逻辑隔离

PG 的 `DATABASE` 是较重的隔离单元，单机多租户/多业务通常用 schema 做“逻辑分库”：

```sql
CREATE SCHEMA tenant_a;
CREATE SCHEMA tenant_b;

CREATE TABLE tenant_a.orders (LIKE orders INCLUDING ALL);
CREATE TABLE tenant_b.orders (LIKE orders INCLUDING ALL);

-- 通过 search_path 切换当前“库”
SET search_path TO tenant_a, public;
```

### 关键注意点

- **分区键必须进主键/唯一约束**：否则无法建主键（PG 要求唯一性在每个分区内可判定）。
- **分区数量不宜过多**：上百个分区后规划时间会明显上升，建议结合时间粒度控制分区数。
- **更新分区键会触发跨分区移动**：`UPDATE` 分区键值可能导致行从一个分区迁到另一个分区，开销较大，应尽量保持分区键不变。
- **单机本质不变**：以上都发生在同一台服务器、同一个实例内，解决的是“大表”问题；要真正跨机器水平扩展仍需 Citus 或分库分表中间件。