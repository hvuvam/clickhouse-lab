# ClickHouse 2-Node Cluster — Ví dụ thực tế

## Tổng quan cluster

| Cluster | Shards | Replicas | Mục đích |
|---|---|---|---|
| `catalog_cluster` | 1 | 2 | Bảng catalog/dimension — DDL propagate toàn cluster |
| `cluster_1s2r` | 1 | 2 | Bảng fact/transaction — truy vấn qua Distributed engine |

**Macros** được gán sẵn trên mỗi node:

| Node | `{cluster}` | `{shard}` | `{replica}` |
|---|---|---|---|
| clickhouse-blue-1 | cluster_1s2r | 1 | r1 |
| clickhouse-blue-2 | cluster_1s2r | 1 | r2 |

> **Quy ước đặt tên:**
> - `example_local` — database chứa bảng local (ReplicatedMergeTree)
> - `example` — database chứa bảng Distributed (view phân tán)

---

## Bước 1 — Tạo Database

```sql
-- Database local (chứa ReplicatedMergeTree)
CREATE DATABASE IF NOT EXISTS example_local
ON CLUSTER 'catalog_cluster';

-- Database distributed (chứa Distributed engine tables)
CREATE DATABASE IF NOT EXISTS example
ON CLUSTER 'catalog_cluster';
```

Kiểm tra:

```sql
SELECT name, engine FROM system.databases WHERE name LIKE 'example%';
```

---

## Bước 2 — Bảng `customers` (catalog_cluster)

### Mục đích
Bảng khách hàng là **dimension table** — dữ liệu nhỏ, cần tồn tại trên cả 2 node để JOIN local mà không cần remote call.  
Dùng `catalog_cluster` để đảm bảo DDL propagate đồng thời lên tất cả node.

### Local table (ReplicatedMergeTree)

```sql
CREATE TABLE IF NOT EXISTS example_local.customers
ON CLUSTER 'catalog_cluster'
(
    customer_id  UInt64,
    name         String,
    email        String,
    phone        Nullable(String),
    segment      LowCardinality(String),   -- e.g. 'VIP', 'REGULAR', 'TRIAL'
    created_at   DateTime DEFAULT now(),
    updated_at   DateTime DEFAULT now(),
    is_active    UInt8 DEFAULT 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/catalog/customers',  -- path cố định, không dùng {shard} vì đây là catalog
    '{replica}'
)
PARTITION BY toYYYYMM(created_at)
ORDER BY (customer_id)
SETTINGS index_granularity = 8192;
```

> **Lưu ý ZooKeeper path**: dùng `/clickhouse/tables/catalog/customers` thay vì `{shard}` vì catalog table không phân mảnh — tất cả replica cùng chia sẻ 1 path prefix.

### Distributed table

```sql
CREATE TABLE IF NOT EXISTS example.customers
ON CLUSTER 'catalog_cluster'
AS example_local.customers
ENGINE = Distributed('catalog_cluster', 'example_local', 'customers', rand());
```

### Insert dữ liệu mẫu

```sql
INSERT INTO example.customers (customer_id, name, email, phone, segment)
VALUES
    (1, 'Nguyen Van A', 'vana@example.com', '0901234567', 'VIP'),
    (2, 'Tran Thi B',   'thib@example.com', NULL,         'REGULAR'),
    (3, 'Le Van C',     'vanc@example.com', '0912345678', 'VIP'),
    (4, 'Pham Thi D',   'thid@example.com', '0923456789', 'TRIAL');
```

### Kiểm tra replication

```sql
-- Kết nối trực tiếp lên từng node để xác nhận data đã replicate
SELECT hostName(), count() FROM remote('clickhouse-blue-1', 'example_local', 'customers');
SELECT hostName(), count() FROM remote('clickhouse-blue-2', 'example_local', 'customers');
```

---

## Bước 3 — Bảng `orders` (cluster_1s2r + hot_cold storage)

### Mục đích
Bảng đơn hàng là **fact table** — dữ liệu lớn, tăng liên tục.  
Dùng policy `hot_cold`:
- **Hot** (local disk): data mới, truy vấn thường xuyên
- **Cold** (S3): data cũ, truy vấn ít hơn — tự động chuyển khi hot disk > 90% (move_factor=0.1)

### Local table (ReplicatedMergeTree + hot_cold)

```sql
CREATE TABLE IF NOT EXISTS example_local.orders
ON CLUSTER 'cluster_1s2r'
(
    order_id      UInt64,
    customer_id   UInt64,
    product_id    UInt64,
    quantity      UInt32,
    unit_price    Decimal(18, 2),
    total_amount  Decimal(18, 2),
    status        LowCardinality(String),  -- 'PENDING','PAID','SHIPPED','DONE','CANCELLED'
    order_date    DateTime,
    updated_at    DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{cluster}/{shard}/orders',
    '{replica}'
)
PARTITION BY toYYYYMM(order_date)
ORDER BY (customer_id, order_date, order_id)
TTL order_date + INTERVAL 3 YEAR DELETE          -- xóa data > 3 năm
SETTINGS
    -- storage_policy = 'hot_cold',
    index_granularity = 8192,
    min_bytes_for_wide_part = 10485760;           -- 10 MB: part nhỏ dùng compact format
```

> **TTL + hot_cold** hoạt động độc lập:
> - TTL DELETE: xóa row sau 3 năm
> - hot_cold: tự động di chuyển phần (part) từ local disk sang S3 khi local disk đầy

### Distributed table

```sql
CREATE TABLE IF NOT EXISTS example.orders
ON CLUSTER 'cluster_1s2r'
AS example_local.orders
ENGINE = Distributed(
    'cluster_1s2r',
    'example_local',
    'orders',
    customer_id   -- sharding key: nhóm đơn hàng của cùng 1 khách hàng về cùng shard
                  -- (với 1 shard thì không phân tán, nhưng sẵn sàng scale lên multi-shard)
);
```

### Insert dữ liệu mẫu

```sql
INSERT INTO example.orders
    (order_id, customer_id, product_id, quantity, unit_price, total_amount, status, order_date)
SELECT
    number + 1                                               AS order_id,
    1 + (rand() % 4)                                         AS customer_id,
    1 + (rand() % 5)                                         AS product_id,
    1 + (rand() % 10)                                        AS quantity,
    round(10 + (rand() % 990), 2)                            AS unit_price,
    round(quantity * unit_price, 2)                          AS total_amount,
    ['PENDING','PAID','SHIPPED','DONE','CANCELLED'][1 + rand() % 5] AS status,
    toDateTime('2023-01-01') + (rand() % (365 * 86400 * 2)) AS order_date
FROM numbers(1000);
```

### Kiểm tra storage policy

```sql
-- Xem parts đang nằm ở disk nào
SELECT
    table,
    disk_name,
    partition,
    count()       AS parts,
    formatReadableSize(sum(bytes_on_disk)) AS size_on_disk
FROM system.parts
WHERE database = 'example_local' AND table = 'orders' AND active
GROUP BY table, disk_name, partition
ORDER BY partition DESC;
```

---

## Bước 4 — Bảng `products` (cluster_1s2r, default storage)

### Mục đích
Bảng sản phẩm là **dimension table nhỏ** nhưng cần JOIN hiệu quả với orders trong cùng query.  
Dùng `cluster_1s2r` để truy vấn qua Distributed engine, **không** dùng hot_cold vì data nhỏ, không cần phân tầng storage.

### Local table (ReplicatedMergeTree, default storage)

```sql
CREATE TABLE IF NOT EXISTS example_local.products
ON CLUSTER 'cluster_1s2r'
(
    product_id    UInt64,
    sku           String,
    name          String,
    category      LowCardinality(String),
    brand         LowCardinality(String),
    cost_price    Decimal(18, 2),
    sell_price    Decimal(18, 2),
    stock         Int32 DEFAULT 0,
    is_active     UInt8 DEFAULT 1,
    created_at    DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{cluster}/{shard}/products',
    '{replica}'
)
PARTITION BY category
ORDER BY (product_id)
SETTINGS index_granularity = 8192;
```

### Distributed table

```sql
CREATE TABLE IF NOT EXISTS example.products
ON CLUSTER 'cluster_1s2r'
AS example_local.products
ENGINE = Distributed('cluster_1s2r', 'example_local', 'products', rand());
```

### Insert dữ liệu mẫu

```sql
INSERT INTO example.products
    (product_id, sku, name, category, brand, cost_price, sell_price, stock)
VALUES
    (1, 'LAPTOP-001', 'Laptop Pro 15',     'Electronics', 'BrandX', 15000000, 18000000, 50),
    (2, 'PHONE-001',  'Smartphone Z10',    'Electronics', 'BrandY',  8000000, 10500000, 120),
    (3, 'SHIRT-001',  'Cotton T-Shirt M',  'Apparel',     'BrandZ',    150000,   350000, 300),
    (4, 'DESK-001',   'Standing Desk 140', 'Furniture',   'BrandW',  3500000,  5200000, 20),
    (5, 'BOOK-001',   'CH In Action',      'Books',       'OReilly',    80000,   250000, 200);
```

---

## Bước 5 — Truy vấn tổng hợp

### Doanh thu theo khách hàng + phân khúc

```sql
SELECT
    c.customer_id,
    c.name,
    c.segment,
    count(o.order_id)              AS total_orders,
    sum(o.total_amount)            AS revenue,
    avg(o.total_amount)            AS avg_order_value,
    max(o.order_date)              AS last_order_date
FROM example.orders AS o
INNER JOIN example.customers AS c ON o.customer_id = c.customer_id
WHERE o.status != 'CANCELLED'
GROUP BY c.customer_id, c.name, c.segment
ORDER BY revenue DESC;
```

### Top sản phẩm bán chạy theo tháng

```sql
SELECT
    toYYYYMM(o.order_date)  AS month,
    p.name                  AS product_name,
    p.category,
    sum(o.quantity)         AS units_sold,
    sum(o.total_amount)     AS revenue
FROM example.orders AS o
INNER JOIN example.products AS p ON o.product_id = p.product_id
WHERE o.status IN ('PAID', 'SHIPPED', 'DONE')
GROUP BY month, product_name, p.category
ORDER BY month DESC, revenue DESC
LIMIT 20;
```

### Kiểm tra replication lag

```sql
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay   AS replication_lag_sec,
    queue_size,
    inserts_in_queue
FROM system.replicas
WHERE database = 'example_local'
ORDER BY table;
```

---

## Bước 6 — Kiểm tra cluster health

```sql
-- Xác nhận tất cả node đều online
SELECT cluster, shard_num, replica_num, host_name, is_local, errors_count
FROM system.clusters
WHERE cluster IN ('cluster_1s2r', 'catalog_cluster');

-- Xem keeper quorum status
SELECT * FROM system.keeper_map_state_machine LIMIT 1;     -- chỉ có trên CH 24+
-- hoặc dùng four-letter command (xem Makefile: make keeper-check)
```

---

## Cleanup

```sql
-- Xóa toàn bộ ví dụ
DROP DATABASE IF EXISTS example       ON CLUSTER 'catalog_cluster';
DROP DATABASE IF EXISTS example_local ON CLUSTER 'catalog_cluster';
```
