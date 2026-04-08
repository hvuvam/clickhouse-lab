docker-compose down
docker volume rm clickhouse-lab_ch-blue-1-data \
                 clickhouse-lab_ch-blue-2-data \
                 clickhouse-lab_ch-keeper-data
docker-compose up -d


curl -s http://data2:8123/?query=SELECT%20version%28%29


docker exec clickhouse-blue-1 clickhouse-client --query "SELECT name, default_roles_all FROM system.users WHERE name='default' FORMAT Vertical;"