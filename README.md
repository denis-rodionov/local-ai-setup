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

## Cluster

After `make install`, start the Kubernetes VM:

```bash
brew install colima
make cluster-up
```

The first start downloads a Linux VM and k3s. It can take several minutes. The Colima profile is named `ai`. The kubeconfig cluster and context are named `local`, in `~/.kube/config`. Lens reads that file. If Lens was already open, use its reload or catalog sync so the new name appears.

While the VM is running, macOS keeps its whole memory allocation, even if the cluster is idle. The normal size is 25 GB (`memory: 25` in `colima/ai.yaml`).

| Command | Effect |
| --- | --- |
| `make cluster-up` | Start the cluster |
| `make cluster-down` | Stop the VM and return its RAM to macOS. Ollama keeps running |
| `make cluster-status` | Show the VM, the node, and the pods |
| `make cluster-memory MEMORY=28` | Restart the cluster with 28 GB. Pods and data stay |
| `make cluster-memory MEMORY=25` | Restart the cluster back at 25 GB |

`MEMORY` is a whole number of gibibytes from 4 to 32. About 30 is the top end while Qwen is loaded, because the model needs roughly 18 GB as well. The restart does not delete the cluster.

Ephemeral storage is the VM root disk, not the RAM. It was 20 GB, which is what Lens showed. It is now 100 GB (`rootDisk: 100` in `colima/ai.yaml`). That disk can only grow. To grow it again, raise `rootDisk` in `colima/ai.yaml` and in `~/.colima/ai/colima.yaml`, then `make cluster-down` and `make cluster-up`.

`make webhook-install` installs a small admission webhook. On pod creation it reads each image manifest. A multi-arch tag that includes arm64 is left alone. A manifest list with no arm64 image is rewritten to the amd64 digest, and QEMU runs that image. Existing pods keep their current spec until they are recreated. `kube-system`, `cert-manager`, and the webhook's own namespace are skipped.

DNS names (`chat.test`, `llm.test`), LiteLLM, and Open WebUI are not installed yet. Those steps are still only described in `PLAN.md`.
