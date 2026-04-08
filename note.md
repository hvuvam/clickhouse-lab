docker-compose down
docker volume rm clickhouse-lab_ch-blue-1-data \
                 clickhouse-lab_ch-blue-2-data \
                 clickhouse-lab_ch-keeper-data
docker-compose up -d