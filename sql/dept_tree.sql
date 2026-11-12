-- =====================================================================
-- PostgreSQL 部门树递归查询演示
-- 对应 cases/部门树查询.md；在 GitHub Actions 的 PostgreSQL 中执行
-- =====================================================================

DROP TABLE IF EXISTS departments;
CREATE TABLE departments (
  id INT PRIMARY KEY,
  name VARCHAR(50) NOT NULL,
  parent_id INT NULL
);
CREATE INDEX idx_parent_id ON departments(parent_id);

INSERT INTO departments (id, name, parent_id) VALUES
(1,  '集团公司',   NULL),
(2,  '技术部',     1),
(3,  '财务部',     1),
(4,  '人事部',     1),
(10, '后端开发组', 2),
(11, '前端开发组', 2),
(12, '测试组',     2),
(20, '会计组',     3),
(21, '出纳组',     3),
(100,'Java小组',   10),
(101,'Go小组',     10),
(102,'Vue小组',    11);

-- ---------- ① 向下查子树（带层级 + 路径） ----------
SELECT '① 技术部及所有下级(带层级+路径)' AS demo;
WITH RECURSIVE dept_tree AS (
    SELECT id, name, parent_id, 1 AS level,
           CAST(name AS VARCHAR(200)) AS path
    FROM departments WHERE id = 2
    UNION ALL
    SELECT d.id, d.name, d.parent_id, dt.level + 1,
           dt.path || ' > ' || d.name
    FROM departments d INNER JOIN dept_tree dt ON d.parent_id = dt.id
)
SELECT id, parent_id, level, path FROM dept_tree ORDER BY path;

-- ---------- ② 自底向上追溯 ----------
SELECT '② Java小组向上追溯' AS demo;
WITH RECURSIVE up_chain AS (
    SELECT id, name, parent_id, 1 AS level FROM departments WHERE id = 100
    UNION ALL
    SELECT d.id, d.name, d.parent_id, u.level + 1
    FROM departments d INNER JOIN up_chain u ON d.id = u.parent_id
)
SELECT id, name, parent_id, level FROM up_chain;

-- ---------- ③ 树形缩进展示 ----------
SELECT '③ 树形缩进展示' AS demo;
WITH RECURSIVE dept_tree AS (
    SELECT id, name, 1 AS level, CAST(name AS VARCHAR(200)) AS path
    FROM departments WHERE id = 1
    UNION ALL
    SELECT d.id, d.name, dt.level + 1,
           dt.path || '/' || LPAD(d.id::text, 3, '0')
    FROM departments d INNER JOIN dept_tree dt ON d.parent_id = dt.id
)
SELECT level,
       REPEAT('    ', level-1) || '+-' || name AS tree_display
FROM dept_tree ORDER BY path;

-- ---------- ④ 各部门子孙节点数统计 ----------
SELECT '④ 各部门子孙节点数' AS demo;
WITH RECURSIVE sub AS (
    SELECT id, id AS root_id FROM departments
    UNION ALL
    SELECT d.id, s.root_id FROM departments d INNER JOIN sub s ON d.parent_id = s.id
)
SELECT root_id, COUNT(*) - 1 AS descendant_count
FROM sub GROUP BY root_id ORDER BY root_id;

-- ---------- ⑤ PG 特有：CYCLE 子句防死循环 ----------
SELECT '⑤ CYCLE子句(含人为构造的闭环)' AS demo;
-- 故意插入闭环: 102(Vue小组) 的 parent 改为 2(技术部), 再把自己挂回102, 形成环
INSERT INTO departments VALUES (999, '循环部门', 102);
UPDATE departments SET parent_id = 999 WHERE id = 102;  -- 102 -> 999 -> 102 闭环

WITH RECURSIVE dept_tree AS (
    SELECT id, name, parent_id, 1 AS level,
           ARRAY[id] AS path_ids,
           FALSE AS is_cycle
    FROM departments WHERE id = 2
    UNION ALL
    SELECT d.id, d.name, d.parent_id, dt.level + 1,
           dt.path_ids || d.id,
           d.id = ANY(dt.path_ids)   -- 手工环检测(兼容9.x); PG14+也可用 CYCLE子句
    FROM departments d INNER JOIN dept_tree dt ON d.parent_id = dt.id
    WHERE NOT dt.is_cycle
)
SELECT id, name, level, is_cycle FROM dept_tree ORDER BY id;

-- 清理闭环数据
DELETE FROM departments WHERE id = 999;
UPDATE departments SET parent_id = 11 WHERE id = 102;
