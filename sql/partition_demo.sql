-- =====================================================================
-- PostgreSQL 单机分库分表（原生声明式分区）演示
-- 覆盖：Range / List / Hash 分区、自动路由、分区裁剪、DETACH 归档、schema 分库
-- 在 GitHub Actions 的 PostgreSQL 16 中执行；可用 -v ON_ERROR_STOP=1 反复运行
-- 内嵌 DO ... ASSERT 断言，任何预期不符都会让 CI 失败
-- =====================================================================

-- ---------- 准备：清理历史对象，保证幂等 ----------
DROP SCHEMA IF EXISTS tenant_a CASCADE;
DROP SCHEMA IF EXISTS tenant_b CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS sales_by_region CASCADE;
DROP TABLE IF EXISTS orders CASCADE;

-- ---------- ① Range 分区（按时间，最适合归档场景） ----------
CREATE TABLE orders (
  id         BIGSERIAL,
  created_at timestamptz NOT NULL,
  amount     numeric(12, 2),
  PRIMARY KEY (id, created_at)   -- 分区键必须包含在主键/唯一约束中
) PARTITION BY RANGE (created_at);

CREATE TABLE orders_2026_01 PARTITION OF orders
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE orders_2026_02 PARTITION OF orders
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE orders_default PARTITION OF orders DEFAULT;

INSERT INTO orders (created_at, amount) VALUES
  ('2026-01-15 10:00:00+08',  99.50),
  ('2026-01-31 23:00:00+08', 199.00),
  ('2026-02-01 00:00:00+08', 128.00),
  ('2027-05-01 00:00:00+08',  50.00);  -- 超出范围，落入 default

SELECT '① Range 分区自动路由：各分区行数' AS demo;
SELECT tableoid::regclass AS part_name, count(*) AS rows
FROM orders GROUP BY tableoid ORDER BY part_name;

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM orders_2026_01) = 2, 'orders_2026_01 应有 2 行';
  ASSERT (SELECT count(*) FROM orders_2026_02) = 1, 'orders_2026_02 应有 1 行';
  ASSERT (SELECT count(*) FROM orders_default) = 1, 'orders_default 应有 1 行';
  ASSERT (SELECT count(*) FROM ONLY orders) = 0,   '父表不应直接存储数据';
END $$;

-- ---------- ② 分区裁剪：验证优化器只扫描相关分区 ----------
DO $$
DECLARE
  plan_text text := '';
  r record;
BEGIN
  FOR r IN EXECUTE
    'EXPLAIN (COSTS OFF) SELECT * FROM orders ' ||
    'WHERE created_at >= ''2026-01-01'' AND created_at < ''2026-02-01'''
  LOOP
    plan_text := plan_text || r."QUERY PLAN" || E'\n';
  END LOOP;

  RAISE NOTICE '分区裁剪执行计划：%', plan_text;
  ASSERT plan_text LIKE '%orders_2026_01%', '分区裁剪失败：未扫描 orders_2026_01';
  ASSERT plan_text NOT LIKE '%orders_2026_02%', '分区裁剪失败：不应扫描 orders_2026_02';
END $$;

-- ---------- ③ List 分区（按地区等离散值） ----------
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
CREATE TABLE sales_other PARTITION OF sales_by_region DEFAULT;

INSERT INTO sales_by_region (region, amount) VALUES
  ('east', 10), ('northeast', 20), ('west', 30), ('north', 40);

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM sales_east)  = 2, 'sales_east 应有 2 行';
  ASSERT (SELECT count(*) FROM sales_west)  = 1, 'sales_west 应有 1 行';
  ASSERT (SELECT count(*) FROM sales_other) = 1, 'sales_other 应有 1 行';
END $$;

-- ---------- ④ Hash 分区（按 id 均匀打散） ----------
CREATE TABLE users (
  id   bigint NOT NULL,
  name text,
  PRIMARY KEY (id)
) PARTITION BY HASH (id);

CREATE TABLE users_p0 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE users_p1 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE users_p2 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE users_p3 PARTITION OF users FOR VALUES WITH (MODULUS 4, REMAINDER 3);

INSERT INTO users (id, name)
SELECT g, 'user_' || g FROM generate_series(1, 1000) AS g;

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM users) = 1000, 'users 应有 1000 行';
  ASSERT (SELECT count(*) FROM users_p0) > 0, 'users_p0 不应为空';
  ASSERT (SELECT count(*) FROM users_p1) > 0, 'users_p1 不应为空';
  ASSERT (SELECT count(*) FROM users_p2) > 0, 'users_p2 不应为空';
  ASSERT (SELECT count(*) FROM users_p3) > 0, 'users_p3 不应为空';
END $$;

-- ---------- ⑤ 快速归档：DETACH 整个分区 ----------
ALTER TABLE orders DETACH PARTITION orders_2026_01;

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM orders) = 2,          'DETACH 后 orders 应剩 2 行';
  ASSERT (SELECT count(*) FROM orders_2026_01) = 2,  '独立表应保留 2 行';
  ASSERT NOT EXISTS (
    SELECT 1 FROM pg_inherits WHERE inhrelid = 'orders_2026_01'::regclass
  ), 'orders_2026_01 应已脱离父表';
END $$;

-- ---------- ⑥ 分库：同实例内用 schema 做逻辑隔离 ----------
CREATE SCHEMA tenant_a;
CREATE SCHEMA tenant_b;

CREATE TABLE tenant_a.orders (LIKE orders INCLUDING ALL);
CREATE TABLE tenant_b.orders (LIKE orders INCLUDING ALL);

INSERT INTO tenant_a.orders (created_at, amount) VALUES ('2026-03-01', 1);
INSERT INTO tenant_b.orders (created_at, amount) VALUES ('2026-03-01', 2);

SET search_path TO tenant_a, public;
SELECT current_schema() AS active_schema;   -- 预期 tenant_a
RESET search_path;

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM tenant_a.orders) = 1, 'tenant_a.orders 应有 1 行';
  ASSERT (SELECT count(*) FROM tenant_b.orders) = 1, 'tenant_b.orders 应有 1 行';
END $$;

-- ---------- 汇总 ----------
SELECT 'OK: Range/List/Hash 分区 + 自动路由 + 分区裁剪 + DETACH + schema 分库 全部通过' AS result;
