#!/usr/bin/env python3
"""Rewrite amd64-only image indexes so an arm64 node can pull them.

A tag or digest that is an OCI index or Docker manifest list is left unchanged
when it contains linux/arm64. When it does not, and it does contain linux/amd64,
the container image is replaced with that amd64 manifest digest. A reference
that is already a single image manifest is left unchanged: this node can pull it.

Attestation entries (os/architecture "unknown") are ignored.
"""

import base64
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
LISTEN_PORT = int(os.environ.get("WEBHOOK_PORT", "8443"))
CACHE_TTL = 600
ERROR_TTL = 30

_cache = {}
_cache_lock = threading.Lock()


def log(message):
    print(message, flush=True)


def parse_image(image):
    """Return (registry, repository, reference). reference is a tag or a digest."""
    rest = image
    digest = None
    if "@" in rest:
        rest, digest = rest.split("@", 1)
    registry = "docker.io"
    if "/" in rest:
        first, remainder = rest.split("/", 1)
        if "." in first or ":" in first or first == "localhost":
            registry = first
            rest = remainder
    if registry == "docker.io" and "/" not in rest:
        rest = "library/" + rest
    name = rest.rsplit("/", 1)[-1]
    if digest:
        repository = rest.rsplit(":", 1)[0] if ":" in name else rest
        return registry, repository, digest
    if ":" in name:
        repository, tag = rest.rsplit(":", 1)
    else:
        repository, tag = rest, "latest"
    return registry, repository, tag


def registry_host(registry):
    if registry == "docker.io":
        return "registry-1.docker.io"
    return registry


def header_map(headers):
    return {key.lower(): value for key, value in headers.items()}


def http_request(url, headers, timeout=8):
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, header_map(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, header_map(error.headers), error.read()


def challenge_token(www_authenticate, basic):
    match = re.match(r"Bearer\s+(.*)", www_authenticate or "", re.IGNORECASE)
    if not match:
        return None
    parts = dict(re.findall(r'(\w+)="([^"]*)"', match.group(1)))
    realm = parts.get("realm")
    if not realm:
        return None
    query = urllib.parse.urlencode(
        {key: parts[key] for key in ("service", "scope") if key in parts}
    )
    separator = "&" if "?" in realm else "?"
    headers = {"Authorization": basic} if basic else {}
    status, _, body = http_request(realm + separator + query, headers)
    if status != 200:
        return None
    payload = json.loads(body)
    token = payload.get("token") or payload.get("access_token")
    return f"Bearer {token}" if token else None


def fetch_manifest(registry, repository, reference, basic=None):
    url = f"https://{registry_host(registry)}/v2/{repository}/manifests/{reference}"
    headers = {"Accept": ACCEPT}
    status, response_headers, body = http_request(url, headers)
    if status == 401:
        token = challenge_token(response_headers.get("www-authenticate"), basic)
        if not token:
            raise RuntimeError(f"registry auth failed for {registry}/{repository}:{tag}")
        headers["Authorization"] = token
        status, response_headers, body = http_request(url, headers)
    if status != 200:
        detail = body[:200].decode("utf-8", "replace")
        raise RuntimeError(
            f"manifest {status} for {registry}/{repository}:{reference}: {detail}"
        )
    media_type = (response_headers.get("content-type") or "").split(";")[0].strip()
    return media_type, json.loads(body)


def classify(media_type, manifest):
    """Return ('arm64', None), ('amd64', digest), ('single', None), or ('other', None)."""
    is_index = media_type in INDEX_TYPES or (
        "manifests" in manifest and "layers" not in manifest
    )
    if not is_index:
        return "single", None
    amd64 = None
    for entry in manifest.get("manifests") or []:
        platform = entry.get("platform") or {}
        operating_system = platform.get("os")
        architecture = platform.get("architecture")
        if operating_system in (None, "unknown") or architecture in (None, "unknown"):
            continue
        if operating_system == "linux" and architecture == "arm64":
            return "arm64", None
        if operating_system == "linux" and architecture == "amd64" and amd64 is None:
            amd64 = entry.get("digest")
    if amd64:
        return "amd64", amd64
    return "other", None


def with_digest(image, digest):
    base = image.split("@", 1)[0]
    if ":" in base.rsplit("/", 1)[-1]:
        base = base.rsplit(":", 1)[0]
    return f"{base}@{digest}"


def cached(image):
    with _cache_lock:
        item = _cache.get(image)
        if item and item[0] > time.time():
            return item[1]
    return None


def store(image, decision, ttl):
    with _cache_lock:
        _cache[image] = (time.time() + ttl, decision)


def registry_names(registry):
    names = {registry}
    if registry in ("docker.io", "index.docker.io", "registry-1.docker.io"):
        names.update(("docker.io", "index.docker.io", "registry-1.docker.io"))
    return names


def auth_host(key):
    host = key.replace("https://", "").replace("http://", "").split("/")[0]
    if host.count(":") == 1 and not host.startswith("["):
        host = host.split(":", 1)[0]
    return host


def basic_for_registry(pod, registry):
    """Optional. Anonymous manifest reads are enough for public images."""
    if not os.environ.get("KUBERNETES_SERVICE_HOST"):
        return None
    namespace = pod.get("metadata", {}).get("namespace")
    if not namespace:
        return None
    names = [
        item.get("name")
        for item in (pod.get("spec", {}).get("imagePullSecrets") or [])
        if item.get("name")
    ]
    for name in names:
        secret = kube_get(f"/api/v1/namespaces/{namespace}/secrets/{name}")
        if not secret:
            continue
        encoded = (secret.get("data") or {}).get(".dockerconfigjson")
        if not encoded:
            continue
        config = json.loads(base64.b64decode(encoded))
        for key, value in (config.get("auths") or {}).items():
            if auth_host(key) not in registry_names(registry):
                continue
            if value.get("auth"):
                return "Basic " + value["auth"]
            if value.get("username"):
                raw = f"{value['username']}:{value.get('password', '')}".encode()
                return "Basic " + base64.b64encode(raw).decode()
    return None


def kube_get(path):
    token = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    context = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    )
    request = urllib.request.Request(
        f"https://{host}:{port}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5, context=context) as response:
            return json.load(response)
    except urllib.error.HTTPError:
        return None


def decide(image, pod=None):
    """Return (reason, replacement or None). replacement is set only for an amd64-only index."""
    hit = cached(image)
    if hit is not None:
        return hit
    registry, repository, reference = parse_image(image)
    try:
        basic = basic_for_registry(pod, registry) if pod else None
        media_type, manifest = fetch_manifest(registry, repository, reference, basic)
        kind, digest = classify(media_type, manifest)
    except Exception as error:
        log(f"lookup failed {image}: {error}")
        decision = ("error", None)
        store(image, decision, ERROR_TTL)
        return decision
    if kind == "amd64" and digest:
        decision = ("amd64", with_digest(image, digest))
    else:
        decision = (kind, None)
    store(image, decision, CACHE_TTL)
    return decision


def container_lists(pod):
    spec = pod.get("spec") or {}
    lists = []
    for key in ("containers", "initContainers", "ephemeralContainers"):
        items = spec.get(key)
        if items:
            lists.append((key, items))
    return lists


def lookup(task):
    key, index, container, image, pod = task
    return key, index, container, image, decide(image, pod)


def patches_for(pod):
    operations = []
    notes = []
    namespace = (pod.get("metadata") or {}).get("namespace", "")
    name = (pod.get("metadata") or {}).get("name", "")
    tasks = []
    for key, containers in container_lists(pod):
        for index, container in enumerate(containers):
            image = container.get("image")
            if image:
                tasks.append((key, index, container, image, pod))
    if not tasks:
        return operations
    workers = min(8, len(tasks))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        looked_up = list(pool.map(lookup, tasks))
    for key, index, container, image, (reason, replacement) in looked_up:
        container_name = container.get("name", str(index))
        if replacement and replacement != image:
            operations.append(
                {
                    "op": "replace",
                    "path": f"/spec/{key}/{index}/image",
                    "value": replacement,
                }
            )
            notes.append(f"{container_name}->amd64")
            log(f"rewrite {namespace}/{name} {container_name} {image} -> {replacement}")
        else:
            log(f"keep {namespace}/{name} {container_name} {image} ({reason})")
    if notes:
        annotations = (pod.get("metadata") or {}).get("annotations")
        value = ",".join(notes)
        if annotations is None:
            operations.append(
                {
                    "op": "add",
                    "path": "/metadata/annotations",
                    "value": {"image-arch-webhook/rewritten": value},
                }
            )
        else:
            operations.append(
                {
                    "op": "add",
                    "path": "/metadata/annotations/image-arch-webhook~1rewritten",
                    "value": value,
                }
            )
    return operations


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        log(f"request {self.command} {self.path}")
        if self.path.split("?", 1)[0].rstrip("/") != "/mutate":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        review = json.loads(self.rfile.read(length) or b"{}")
        request = review.get("request") or {}
        uid = request.get("uid")
        pod = request.get("object") or {}
        try:
            operations = patches_for(pod)
            response = {"uid": uid, "allowed": True}
            if operations:
                encoded = base64.b64encode(json.dumps(operations).encode()).decode()
                response["patchType"] = "JSONPatch"
                response["patch"] = encoded
        except Exception as error:
            log(f"admit error: {error}")
            response = {"uid": uid, "allowed": True}
        body = json.dumps(
            {
                "apiVersion": "admission.k8s.io/v1",
                "kind": "AdmissionReview",
                "response": response,
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def serve():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    log(f"listening on {LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--resolve":
        for item in sys.argv[2:]:
            reason, replacement = decide(item)
            print(f"{item}\t{reason}\t{replacement or ''}")
    else:
        serve()
