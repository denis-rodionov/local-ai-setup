# Plan

Status: steps 1 through 4 are done on this Mac. Step 6, names and certificates, is also done. Next is step 5. Finish a step, check the result, then start the next one. Each step adds files to this repo and applies only those files.

Step 3 installed cert-manager and the image webhook. Step 6 is the DNS and CA setup below. Repeat that section on a new Mac after the cluster and cert-manager exist. Keep the CA that is already in `~/.local-ca/`. A second CA makes the certificates that are already issued untrusted.

## Step 1 — Ollama as a login service (done)

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

## Step 2 — Empty k3s cluster (done)

Add `colima/ai.yaml` and a script that copies it to `~/.colima/ai/colima.yaml` only if that profile does not exist yet, then runs `colima start --profile ai`.

The file sets `vmType: vz`, `mountType: virtiofs`, 4 CPUs, 25 GiB RAM, 100 GiB root disk, 160 GiB data disk, `gatewayAddress: 192.168.5.2`, Kubernetes `v1.35.0+k3s1`, and a `k3sArgs` list that does not contain `--disable=traefik`. Colima's default list disables Traefik. The first check is that the override actually won.

k3s listens on 6443 inside the guest. On this Mac another SSH tunnel already owns `127.0.0.1:6443`, so `scripts/cluster.sh` forwards the guest API to `127.0.0.1:6445` and points the `local` context there.

Those 25 GiB are reserved on the Mac for the whole time the VM is running. `make cluster-memory MEMORY=30` raises it with a restart. `make cluster-memory MEMORY=25` puts it back. Do not switch this profile to krunkit. On Colima 0.10 that engine can leave the data disk unmounted after a restart.

Done when:

- `kubectl --context local get nodes` shows one Ready node
- `kubectl --context local get pods -A` shows Traefik running
- No application pods exist yet

If Traefik is missing, fix `k3sArgs` before step 6. Do not deploy LiteLLM yet.

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

Stop unloads Ollama, so the model leaves memory, and stops the Colima cluster, so the 25 GB reservation returns to macOS. Start loads `qwen3.8:27b-mlx` again and starts the cluster. This is not `make down` from step 9. That later command stops only the VM and leaves Ollama running.

Done when:

- Cmd+Space, then `Stop Local AI`, stops Ollama and the cluster, and `ollama ps` shows no loaded model
- Cmd+Space, then `Start Local AI`, brings the API back with `qwen3.8:27b-mlx` loaded and `kubectl --context local get nodes` shows the node Ready
- Neither action opens Terminal

## Step 5 — Pod to Ollama

Switch the LaunchAgent to `OLLAMA_HOST=0.0.0.0:11434` and restart it, so the VM can open a connection. Loopback still works for the `ollama` CLI.

Add a one-off check, not a permanent app: a short-lived pod curls `http://192.168.5.2:11434/api/tags`.

Done when the pod prints the model list.

If the pod cannot reach the gateway, stop. Add a small bridge manifest in `deploy/ai/ollama-bridge/` and point LiteLLM at that Service instead of the gateway IP. Do not paper over it inside LiteLLM config until the bridge is green.

## Step 6 — Names and TLS (done)

Two resolvers and one CA. The cluster half is `make dns-install`. The Mac half is a hosts block, a key pair under `~/.local-ca/`, and one trusted root. Colima already forwards guest ports 80 and 443 to the Mac, so the browser reaches Traefik at `127.0.0.1` with no extra firewall rule.

### Mac names

Add a marked block to `/etc/hosts`. Each name points at `127.0.0.1`. A new browser hostname is another name in this block, plus an Ingress. Pods do not use this file. On this Mac the block is:

```text
# aihub-local begin
127.0.0.1 aihub.test api.aihub.test auth.aihub.test dagster.aihub.test datalake.aihub.test langfuse.aihub.test openwebui.aihub.test s3.aihub.test sysadmin.aihub.test
127.0.0.1 denistest.test api.denistest.test auth.denistest.test dagster.denistest.test datalake.denistest.test langfuse.denistest.test openwebui.denistest.test s3.denistest.test sysadmin.denistest.test
# aihub-local end
```

Editing `/etc/hosts` needs sudo. The block survives a reboot.

### Pod names

`deploy/system/coredns-custom.yaml` is the only `test:53` block. k3s imports ConfigMap `kube-system/coredns-custom`. An A query is a CNAME to `traefik.kube-system.svc.cluster.local`. An AAAA query is NOERROR with no record.

`make dns-install` applies that file and restarts CoreDNS. Run it again when the cluster is recreated. Do not add a second `test:53` block, and do not rewrite the zone with `answer name`. Either one crash-loops CoreDNS.

### The CA

Skip this when `~/.local-ca/ca.crt` is already the CA the cluster uses. Otherwise create it once:

```bash
mkdir -p ~/.local-ca
chmod 700 ~/.local-ca
openssl ecparam -name prime256v1 -genkey -noout -out ~/.local-ca/ca.key
chmod 600 ~/.local-ca/ca.key
openssl req -new -x509 -key ~/.local-ca/ca.key -sha256 -days 3650 \
  -subj "/CN=Local .test CA" \
  -out ~/.local-ca/ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "nameConstraints=critical,permitted;DNS:test"
```

Trust that public file in the login keychain. macOS asks for approval:

```bash
security add-trusted-cert -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db \
  ~/.local-ca/ca.crt
```

After cert-manager is installed, give it the same key pair and a ClusterIssuer. The Secret has to be in the `cert-manager` namespace:

```bash
kubectl --context local -n cert-manager create secret tls local-ca \
  --cert="$HOME/.local-ca/ca.crt" \
  --key="$HOME/.local-ca/ca.key"
kubectl --context local apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca
spec:
  ca:
    secretName: local-ca
EOF
```

An Ingress that wants a certificate sets `cert-manager.io/cluster-issuer: local-ca`.

A pod that calls `https://…test` gets a ConfigMap of the public certificate only:

```bash
kubectl --context local -n NAMESPACE create configmap local-test-ca \
  --from-file=ca.crt="$HOME/.local-ca/ca.crt"
```

Secret `cert-manager/local-ca` also contains `tls.key`. Leave it in `cert-manager`. The same rule applies to any older CA secret: the private key does not go into an application namespace.

Done when:

- `dscacheutil -q host -a name aihub.test` returns `127.0.0.1`
- `curl -sS -o /dev/null -w '%{http_code}\n' https://aihub.test` prints `200` and the certificate verifies
- `kubectl --context local get clusterissuer local-ca` shows Ready
- A pod resolves `auth.aihub.test` to the Traefik ClusterIP
- `~/.local-ca/ca.key` is not in git

## Step 7 — LiteLLM at llm.test

Add the `ai` namespace, the LiteLLM Deployment, Service, ConfigMap, and Ingress.

The committed config has one alias, `local` → `ollama_chat/qwen3.8:27b-mlx` at `http://192.168.5.2:11434` (or the bridge URL from step 5). The master key comes from `.env` into a Secret. `.env.example` and `.gitignore` land in this step.

Ingress host: `llm.test`. Pods use `http://litellm.ai.svc.cluster.local:4000/v1`.

Done when:

- `https://llm.test/v1/models` returns `local` and requires the master key
- A chat completion on that URL returns text from Qwen
- The same call from a pod, via the cluster DNS name, returns text

## Step 8 — Open WebUI at chat.test

Add the Open WebUI Deployment, Service, Ingress, and `hostPath` volume at `/Users/denis/.local-ai/open-webui`.

The container's OpenAI base URL is the cluster DNS name of LiteLLM, not `https://llm.test`. `ENABLE_OLLAMA_API` is false. `WEBUI_URL` is `https://chat.test`.

Done when:

- `https://chat.test` opens, you create the admin user, and a second chat is a separate session
- The model picker shows `local` and not a duplicate Ollama entry
- A reply arrives from Qwen
- You have looked at a thinking reply and either accepted it or asked to add a direct Ollama connection
- Restarting the pod keeps the chats (they are on the Mac disk)

## Step 9 — Start at login

Add `host/launchagents/com.local-ai.stack.plist`. At login it starts the Colima profile and applies the manifests. It does not restart Ollama; that agent already has `RunAtLoad`. The `/etc/hosts` block and the login-keychain trust are already on the Mac. After a cluster is recreated, run `make dns-install` again and recreate Secret `cert-manager/local-ca` from `~/.local-ca/` if the Secret is gone.

`make down` stops the VM until the next login or the next `make up`. It leaves Ollama running.

Done when a logout and login, or a reboot, brings back `https://chat.test` without a terminal. If a reboot is inconvenient, this step waits until you can do one.

## Step 10 — RAG, still inside Open WebUI

No new Deployment. In the UI, add a Knowledge collection, upload a small document, and ask a question that uses it. Embeddings stay on the small model already configured in the Open WebUI image (`sentence-transformers/all-MiniLM-L6-v2`), running in the pod.

Done when a question answers from the uploaded file, and the file is still there after a pod restart.

Catalog tools, if you want one, are installed from the Open WebUI tools page in this step. They persist in the same data directory. They are not copied into git.

## Step 11 — Pattern for a downloaded app

Add `deploy/agents/example/` and do not reference it from the main kustomization. It contains a Deployment and an Ingress for `example.test` with the LiteLLM env vars from the architecture. The image is a placeholder that must not be pulled.

Done when you have read it and named a real app, or decided to stay with Open WebUI tools for now. A real app is a new step, with its own hostname, after you choose it.

## Step 12 — OpenRouter alias

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
