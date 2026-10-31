# Plan

Status: accepted. Finish a step, check the result, then start the next one. Each step adds files to this repo and applies only those files.

Current terminal `ollama serve` keeps working until step 1 replaces it.

## Step 1 — Ollama as a login service

Add `host/launchagents/com.local-ai.ollama.plist`, `scripts/ollama.sh`, and Makefile targets.

| Command | Effect |
| --- | --- |
| `make ollama-start` | Install the agent, start Ollama now, load `qwen3.8:27b-mlx` |
| `make ollama-stop` | Stop it until the next login or the next start |
| `make ollama-status` | Show the process, the API, and whether login start is on |
| `make ollama-disable` | Stop it and do not start it at login |
| `make ollama-enable` | Allow login start again |

The agent binds `127.0.0.1:11434`. Before the first bootstrap, stop the `ollama serve` that is running in the terminal, or the agent will crash-loop on that port.

Done when:

- `launchctl print gui/$UID/com.local-ai.ollama` shows the agent running
- `curl -s http://127.0.0.1:11434/api/tags` lists `qwen3.8:27b-mlx`
- Closing the terminal does not stop the API
- One short generate keeps the model loaded (`OLLAMA_KEEP_ALIVE=-1`)

## Step 2 — Empty k3s cluster

Add `colima/ai.yaml` and a script that copies it to `~/.colima/ai/colima.yaml` only if that profile does not exist yet, then runs `colima start --profile ai`.

The file sets `vmType: vz`, `mountType: virtiofs`, 4 CPUs, 10 GiB RAM, 60 GiB disk, `gatewayAddress: 192.168.5.2`, Kubernetes `v1.35.0+k3s1`, and a `k3sArgs` list that does not contain `--disable=traefik`. Colima's default list disables Traefik. The first check is that the override actually won.

Done when:

- `kubectl --context colima-ai get nodes` shows one Ready node
- `kubectl --context colima-ai get pods -A` shows Traefik running
- No application pods exist yet

If Traefik is missing, fix `k3sArgs` before step 4. Do not deploy LiteLLM yet.

## Step 3 — Pod to Ollama

Switch the LaunchAgent to `OLLAMA_HOST=0.0.0.0:11434` and restart it, so the VM can open a connection. Loopback still works for the `ollama` CLI.

Add a one-off check, not a permanent app: a short-lived pod curls `http://192.168.5.2:11434/api/tags`.

Done when the pod prints the model list.

If the pod cannot reach the gateway, stop. Add a small bridge manifest in `deploy/ai/ollama-bridge/` and point LiteLLM at that Service instead of the gateway IP. Do not paper over it inside LiteLLM config until the bridge is green.

## Step 4 — Names and TLS

Add:

- `host/dns/dnsmasq.conf` and `host/launchagents/com.local-ai.dns.plist` (dnsmasq on `127.0.0.1:5353`)
- `host/dns/resolver`, installed to `/etc/resolver/test` (sudo)
- `host/pf/com.local-ai.conf.template`, rendered with the guest IP and loaded as a pf anchor (sudo)
- `deploy/system/traefik.yaml` to redirect HTTP to HTTPS
- a throwaway Ingress `hello.test` and a mkcert wildcard for `*.test`

The certificate and the rendered pf rule are local files, gitignored. mkcert's root is installed into the login keychain.

The pf anchor only redirects `127.0.0.1` ports 80 and 443 on `lo0`, and blocks inbound TCP `11434` on `en0` and `en1`.

Done when:

- `dscacheutil -q host -a name chat.test` returns `127.0.0.1`
- `https://hello.test` loads in the browser with a trusted certificate and no port in the URL
- `http://hello.test` redirects to HTTPS
- From another device on the LAN, port `11434` on this Mac does not accept a connection

Then delete the hello Ingress. Leave DNS, pf, and Traefik in place.

## Step 5 — LiteLLM at llm.test

Add the `ai` namespace, the LiteLLM Deployment, Service, ConfigMap, and Ingress.

The committed config has one alias, `local` → `ollama_chat/qwen3.8:27b-mlx` at `http://192.168.5.2:11434` (or the bridge URL from step 3). The master key comes from `.env` into a Secret. `.env.example` and `.gitignore` land in this step.

Ingress host: `llm.test`. Pods use `http://litellm.ai.svc.cluster.local:4000/v1`.

Done when:

- `https://llm.test/v1/models` returns `local` and requires the master key
- A chat completion on that URL returns text from Qwen
- The same call from a pod, via the cluster DNS name, returns text

## Step 6 — Open WebUI at chat.test

Add the Open WebUI Deployment, Service, Ingress, and `hostPath` volume at `/Users/denis/.local-ai/open-webui`.

The container's OpenAI base URL is the cluster DNS name of LiteLLM, not `https://llm.test`. `ENABLE_OLLAMA_API` is false. `WEBUI_URL` is `https://chat.test`.

Done when:

- `https://chat.test` opens, you create the admin user, and a second chat is a separate session
- The model picker shows `local` and not a duplicate Ollama entry
- A reply arrives from Qwen
- You have looked at a thinking reply and either accepted it or asked to add a direct Ollama connection
- Restarting the pod keeps the chats (they are on the Mac disk)

## Step 7 — Start at login

Add `host/launchagents/com.local-ai.stack.plist`. At login it starts the Colima profile, refreshes the pf guest address, and applies the manifests. It does not restart Ollama or dnsmasq; those agents already have `RunAtLoad`.

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
| `make apply` | Re-render secrets and pf, then `kubectl apply -k` |
| `make status` | Ollama, Colima, pods, DNS |
| `make down` | Stop the VM, leave Ollama running |

`make up` is not safe until the step it would run has been checked. Early steps get their own targets (`make ollama`, `make cluster`, and so on) so a full `make up` is not the way to begin.
