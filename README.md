## Network

`docker network create datalake-net`

## Architecture

**2-node ClickHouse cluster (1 shard, 2 replicas — zero-shard design)**

| Container | Role | Ports | Keeper |
|---|---|---|---|
| `clickhouse-blue-1` | Active (shard=1, replica=r1) | 8123, 9900 | id=1 |
| `clickhouse-blue-2` | Replica (shard=1, replica=r2) | 8124, 9901 | id=2 |
| `clickhouse-keeper` | Keeper-only (Raft quorum) | 9183 | id=3 |

The standalone `clickhouse-keeper` container provides the 3rd Raft vote — required for proper quorum (majority = 2 of 3) without running a full CH server.

## Verifying Cluster State

```sql
    SELECT
        host_name,
        host_address,
        replica_num
    FROM system.clusters
    WHERE cluster = 'cluster_1s2r'
```

## Sample Data

```sql
    CREATE DATABASE dbx_local ON CLUSTER 'cluster_1s2r';
    CREATE DATABASE lab ON CLUSTER 'cluster_1s2r';

    -- local replicated table
    CREATE TABLE dbx_local.events ON CLUSTER 'cluster_1s2r' (
        time DateTime,
        event_id  Int32,
        uuid UUID
    )
    ENGINE = ReplicatedMergeTree('/clickhouse/tables/{cluster}/{shard}/events_v01', '{replica}')
    PARTITION BY toYYYYMM(time)
    ORDER BY (event_id);

    -- distributed table view
    CREATE TABLE lab.events ON CLUSTER 'cluster_1s2r' AS dbx_local.events
    ENGINE = Distributed('cluster_1s2r', 'dbx_local', 'events', event_id);

    -- generate data
    INSERT INTO lab.events(time, event_id, uuid)
    SELECT toDateTime('2022-01-01 00:00:00') + (rand() % (toDateTime('2023-12-31 23:59:59') - toDateTime('2022-01-01 00:00:00'))) tim,
        (1 + rand() % 1000000) as event_id, 
        b FROM generateRandom('b UUID', 1, 10, 2) 
    LIMIT 1000;

    -- checks
    select count() from dbx_local.events;
    select count() from lab.events;
```

### Query both replicas

```sql
SELECT * FROM
(
    SELECT hostName(), *
    FROM remote('clickhouse-blue-1', 'dbx_local', 'events')
    UNION ALL
    SELECT hostName(), *
    FROM remote('clickhouse-blue-2', 'dbx_local', 'events')
);
```

## Keeper Health Check

```bash
make keeper-check
# or manually:
echo ruok | nc 127.0.0.1 9181   # blue-1 keeper
echo ruok | nc 127.0.0.1 9182   # blue-2 keeper
echo ruok | nc 127.0.0.1 9183   # standalone keeper
```

docker exec clickhouse-blue-1 bash -c "nc -zv clickhouse-blue-2 9234 && echo OK"
docker exec clickhouse-blue-1 bash -c "nc -zv clickhouse-keeper 9234 && echo OK"