.PHONY: install ollama-start ollama-stop ollama-status ollama-enable ollama-disable

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
