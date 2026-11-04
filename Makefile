.PHONY: install ollama-start ollama-stop ollama-status ollama-enable ollama-disable \
	cluster-up cluster-down cluster-status cluster-memory webhook-install \
	stack-stop stack-start spotlight

install:
	./scripts/install.sh

ollama-start:
	./scripts/ollama.sh start

ollama-stop:
	./scripts/ollama.sh stop

ollama-status:
	./scripts/ollama.sh status

ollama-enable:
	./scripts/ollama.sh enable

ollama-disable:
	./scripts/ollama.sh disable

cluster-up:
	./scripts/cluster.sh up

cluster-down:
	./scripts/cluster.sh down

cluster-status:
	./scripts/cluster.sh status

cluster-memory:
	./scripts/cluster.sh memory

webhook-install:
	./deploy/image-arch-webhook/install.sh

stack-stop:
	./scripts/stack.sh stop

stack-start:
	./scripts/stack.sh start

spotlight:
	./scripts/spotlight.sh
