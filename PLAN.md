# Plan

Status: steps 1 through 5 are done on this Mac. Next is step 6. Finish a step, check the result, then start the next one. Each step adds files to this repo and applies only those files.

Step 3 installed cert-manager and the image webhook. Names under `.test` and ClusterIssuer `local-ca` are already on this Mac. `ARCHITECTURE.md` records how to repeat them. Keep the CA that is already in `~/.local-ca/`. A second CA makes the certificates that are already issued untrusted.

## Step 1 — Ollama as a login service (done)

Add `host/launchagents/com.local-ai.ollama.plist`, `scripts/ollama.sh`, and Makefile targets.

| Command | Effect |
| --- | --- |
| `make ollama-start` | Install the agent, start Ollama now, load `qwen3.8:27b-mlx` |
| `make ollama-stop` | Stop it until the next login or the next start |
| `make ollama-status` | Show the process, the API, and whether login start is on |
| `make ollama-disable` | Stop it and do not start it at login |
| `make ollama-enable` | Allow login start again |

The agent binds `0.0.0.0:11434`, so the VM can connect. The `ollama` command on the Mac still uses `127.0.0.1`. Before the first bootstrap, stop any `ollama serve` that is running in a terminal, or the agent will crash-loop on that port.

Done when:

- `launchctl print gui/$UID/com.local-ai.ollama` shows the agent running
- `curl -s http://127.0.0.1:11434/api/tags` lists `qwen3.8:27b-mlx`
- Closing the terminal does not stop the API
- One short generate keeps the model loaded (`OLLAMA_KEEP_ALIVE=-1`)

## Step 2 — Empty k3s cluster (done)

Add `colima/ai.yaml` and a script that copies it to `~/.colima/ai/colima.yaml` only if that profile does not exist yet, then runs `colima start --profile ai`.

The file sets `vmType: vz`, `mountType: virtiofs`, 4 CPUs, 25 GiB RAM, 100 GiB root disk, 160 GiB data disk, `gatewayAddress: 192.168.5.2`, Kubernetes `v1.35.0+k3s1`, and a `k3sArgs` list that does not contain `--disable=traefik`. Colima's default list disables Traefik. The first check is that the override actually won.

k3s listens on 6443 inside the guest. On this Mac another SSH tunnel already owns `127.0.0.1:6443`, so `scripts/cluster.sh` forwards the guest API to `127.0.0.1:6445` and points the `local` context there.

Those 25 GiB are reserved on the Mac for the whole time the VM is running. `make cluster-memory MEMORY=30` raises it with a restart. `make cluster-memory MEMORY=25` puts it back. Do not switch this profile to krunkit. On Colima 0.10 that engine can leave the data disk unmounted after a restart.

Done when:

- `kubectl --context local get nodes` shows one Ready node
- `kubectl --context local get pods -A` shows Traefik running
- No application pods exist yet

If Traefik is missing, fix `k3sArgs` before step 5. Do not deploy LiteLLM yet.

## Step 3 — Image admission webhook (done)

`make webhook-install` installs cert-manager `v1.18.2` when the cluster does not already have it, then installs the webhook. The serving certificate comes from cert-manager.

On pod creation the webhook reads each image manifest. A tag or digest that includes arm64 is left alone, so the node pulls the native image. A manifest list with no arm64 build, including one pinned by its index digest, is rewritten to the amd64 manifest digest, and QEMU runs that image. A single image manifest is left alone. `kube-system`, `cert-manager`, and `image-arch-webhook` are skipped. Pods that already exist keep their spec until they are recreated.

Done when:

- `kubectl --context local get mutatingwebhookconfiguration image-arch-webhook` shows a non-empty `caBundle`
- The webhook deployment is Ready
- A new pod whose image is an amd64-only manifest list is admitted with the amd64 digest
- A new pod whose image includes arm64 keeps the original tag

## Step 4 — Quick stop and start (done)

A way to pause the whole local setup without opening a terminal, and to bring it back the same way. Cmd+Space is the way to launch it. A Finder Quick Action is a Services-menu item, so the thing Spotlight opens is a small app.

Stop unloads Ollama, so the model leaves memory, and stops the Colima cluster, so the 25 GB reservation returns to macOS. Start loads `qwen3.8:27b-mlx` again and starts the cluster. This is not `make down` from step 7. That later command stops only the VM and leaves Ollama running.

Done when:

- Cmd+Space, then `Stop Local AI`, stops Ollama and the cluster, and `ollama ps` shows no loaded model
- Cmd+Space, then `Start Local AI`, brings the API back with `qwen3.8:27b-mlx` loaded and `kubectl --context local get nodes` shows the node Ready
- Neither action opens Terminal

## Step 5 — LiteLLM at llm.test (done)

Install LiteLLM so `https://llm.test` reaches Qwen. Pods cannot open the Colima gateway, even though the VM can. Do not point LiteLLM at `192.168.5.2`. The bridge in `deploy/ai/ollama-bridge/` runs on the VM network and proxies to `http://192.168.5.2:11434`. LiteLLM calls `http://ollama-bridge.ai.svc.cluster.local:11434`.

Copy `.env.example` to `.env` and set `LITELLM_MASTER_KEY`. `make litellm-install` stores that key in a Secret, then applies the `ai` namespace, the bridge, and the LiteLLM Deployment, Service, ConfigMap, and Ingress. The certificate comes from ClusterIssuer `local-ca`. The alias is `local` → `ollama_chat/qwen3.8:27b-mlx`. Pods use `http://litellm.ai.svc.cluster.local:4000/v1`.

Add `llm.test` to the `# aihub-local` block in `/etc/hosts`. Editing that file needs an administrator password. A shell that has not sourced `.env` does not have the key.

Done when this returns text from Qwen:

```bash
set -a && source .env && set +a
curl -sS https://llm.test/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Say hello."}]}'
```

## Step 6 — Open WebUI at chat.test

Add the Open WebUI Deployment, Service, Ingress, and `hostPath` volume at `/Users/denis/.local-ai/open-webui`. Add `chat.test` to the same `/etc/hosts` block as `llm.test`. The certificate comes from ClusterIssuer `local-ca`.

The container's OpenAI base URL is `http://litellm.ai.svc.cluster.local:4000/v1`, with the master key from the existing Secret. `ENABLE_OLLAMA_API` is false. `WEBUI_URL` is `https://chat.test`.

Done when:

- `https://chat.test` opens, you create the admin user, and a second chat is a separate session
- The model picker shows `local` and not a duplicate Ollama entry
- A reply arrives from Qwen
- You have looked at a thinking reply and either accepted it or asked to add a direct Ollama connection
- Restarting the pod keeps the chats (they are on the Mac disk)

## Step 7 — Start at login

Add `host/launchagents/com.local-ai.stack.plist`. At login it starts the Colima profile and applies the manifests. It does not restart Ollama; that agent already has `RunAtLoad`. The `/etc/hosts` block and the login-keychain trust are already on the Mac. After a cluster is recreated, run `make dns-install` again. Recreate Secret `cert-manager/local-ca` from `~/.local-ca/` if that Secret is gone, and run `make litellm-install` again so the LiteLLM Secret comes back from `.env`.

`make down` stops the VM until the next login or the next `make up`. It leaves Ollama running.

Done when a logout and login, or a reboot, brings back `https://chat.test` without a terminal. If a reboot is inconvenient, this step waits until you can do one.

## Step 8 — RAG, still inside Open WebUI

No new Deployment. In the UI, add a Knowledge collection, upload a small document, and ask a question that uses it. Embeddings stay on the small model already configured in the Open WebUI image (`sentence-transformers/all-MiniLM-L6-v2`), running in the pod.

Done when a question answers from the uploaded file, and the file is still there after a pod restart.

Catalog tools, if you want one, are installed from the Open WebUI tools page in this step. They persist in the same data directory. They are not copied into git.

## Step 9 — Pattern for a downloaded app

Add `deploy/agents/example/` and do not reference it from the main kustomization. It contains a Deployment and an Ingress for `example.test` with the LiteLLM env vars from the architecture. The image is a placeholder that must not be pulled.

Done when you have read it and named a real app, or decided to stay with Open WebUI tools for now. A real app is a new step, with its own hostname, after you choose it.

## Step 10 — OpenRouter alias

Add `deploy/overlays/openrouter/`. It adds the `strong` alias. Apply it only when `OPENROUTER_API_KEY` is set in `.env`. The key is not written into the ConfigMap. You set `OPENROUTER_MODEL` to an id copied from OpenRouter, with the `openrouter/` prefix LiteLLM expects.

Done when `https://llm.test/v1/models` lists `local` and `strong`, and a short `strong` completion returns text from the cloud model. `local` still works with the key removed from the request's model field.

## Commands the repo will grow

| Command | What it does |
| --- | --- |
| `make up` | Run every step that is already implemented |
| `make apply` | Re-render secrets, then `kubectl apply -k` |
| `make status` | Ollama, Colima, pods, DNS |
| `make down` | Stop the VM, leave Ollama running |

`make up` is not safe until the step it would run has been checked. Early steps get their own targets (`make ollama`, `make cluster`, and so on) so a full `make up` is not the way to begin.
