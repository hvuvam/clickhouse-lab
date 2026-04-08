.PHONY: up
up:
	docker-compose up -d

.PHONY: down
down:
	docker-compose down

restart:
	docker-compose restart

client:
	docker exec -it clickhouse-blue-1 clickhouse-client

logs:
	docker logs -f clickhouse-blue-1 --tail=1000

ps:
	docker-compose ps
	
.PHONY: keeper-check
keeper-check:
	@echo "=== clickhouse-blue-1 (keeper id=1) ==="
	echo ruok | nc 127.0.0.1 9181
	@printf "\n"
	@echo "=== clickhouse-blue-2 (keeper id=2) ==="
	echo ruok | nc 127.0.0.1 9182
	@printf "\n"
	@echo "=== clickhouse-keeper (keeper id=3) ==="
	echo ruok | nc 127.0.0.1 9183
	@printf "\n"

