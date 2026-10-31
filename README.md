# Local AI

Ollama runs on the Mac and uses the Apple GPU. Everything else will run in a Colima k3s cluster. The layout is in `ARCHITECTURE.md`. Later steps are in `PLAN.md`.

This install is for an Apple Silicon Mac with Homebrew at `/opt/homebrew`. The login agent calls `/opt/homebrew/opt/ollama/bin/ollama`.

## Install on a fresh Mac

Install Homebrew if it is missing: https://brew.sh

If `make` is not found, install the command-line tools (`xcode-select --install`). Clone this repo, enter it, and run:

```bash
make install
```

That installs Ollama and Python 3, downloads `qwen3.8:27b-mlx` (about 18 GB) if it is not already present, installs the login agent, and loads the model. Running it again is safe. When the agent is already up and Qwen is loaded, it leaves them running.

You want `make ollama-status` to show `agent: loaded`, `login start: enabled`, `api: up`, and `loaded: qwen3.8:27b-mlx`.

The server then starts at each login, with no terminal window. The weights do not load at login. They load on the first request, or when you run `make ollama-start`, and stay resident until you stop the agent or reboot.

Do not also run `brew services start ollama` or `ollama serve` in a terminal. A second server cannot bind port 11434.

## Day to day

The server listens on `127.0.0.1:11434`.

| Command | Effect |
| --- | --- |
| `make ollama-start` | Start the server now and load Qwen |
| `make ollama-stop` | Stop it until the next login or the next start |
| `make ollama-status` | Show the process, the API, and whether login start is on |
| `make ollama-disable` | Stop it and do not start it at login |
| `make ollama-enable` | Allow login start again, without starting it now |

Logs: `~/Library/Logs/local-ai/ollama.log`

## Not installed yet

The cluster, DNS names (`chat.test`, `llm.test`), LiteLLM, and Open WebUI are not installed. Those steps are still only described in `PLAN.md`.
