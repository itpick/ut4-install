# Deploying the full UT4 server stack (master + game server + hub)

A worked, end-to-end example of running the **entire** UT4 (UE5.8) backend yourself:
the **master server** (accounts / login / server browser), an optional **XMPP**
presence service, one or more **dedicated match servers**, and a **hub** (lobby that
spawns match instances on demand).

The [README's *"Running your own server or hub"*](../README.md#running-your-own-server-or-hub)
section covers the quick case — unzip the server package and run one binary against
a master that already exists. **This guide is the full picture**: how to stand up
*your own* master, wire a hub and dedicated servers to it, and — the hard-won part —
make servers behind NAT / a tunnel register their **real public address** instead of
a useless pod / container IP.

The examples are drawn from a real deployment that runs on a home **Talos Kubernetes
cluster** managed by **Flux (GitOps)**, but every manifest here is generic and
reusable. If you don't run Flux, the same YAML applies with plain `kubectl apply`;
Flux-specific notes are called out.

> **Placeholders.** Everything in `<ANGLE_BRACKETS>` is yours to fill in. Documentation
> IPs (`203.0.113.x`, `198.51.100.x`, RFC 5737) and `example.com` domains stand in for
> real values. **Never** commit real secrets (playit tokens, Mongo creds, OAuth
> secrets) in plaintext — see [Secrets](#secrets-sops--sealed-secrets).

---

## Table of contents

1. [Architecture at a glance](#1-architecture-at-a-glance)
2. [Prerequisites](#2-prerequisites)
3. [Container images](#3-container-images)
4. [Namespace & secrets](#4-namespace--secrets)
5. [Master server (API + MongoDB + web)](#5-master-server-api--mongodb--web)
6. [XMPP presence service (optional)](#6-xmpp-presence-service-optional)
7. [Dedicated match server](#7-dedicated-match-server)
8. [Hub (lobby)](#8-hub-lobby)
9. [Public networking with playit.gg](#9-public-networking-with-playitgg)
10. [The address-override chain (the important gotcha)](#10-the-address-override-chain-the-important-gotcha)
11. [Verification](#11-verification)
12. [Flux / GitOps wiring](#12-flux--gitops-wiring)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Architecture at a glance

```
                          players (public internet)
                                    │
                  ┌─────────────────┼──────────────────────┐
                  │ HTTPS                                   │ UDP game+beacon
                  ▼ (login, browser, API)                  ▼ (playit tunnel)
        ┌───────────────────┐               ┌──────────────────────────────┐
        │  Master server    │               │  playit.gg  <PUBLIC_IP>:PORT │
        │  https://<HOST>   │               └───────────────┬──────────────┘
        │                   │                               │ forwards to 127.0.0.1
        │  ┌─────────────┐  │                               ▼
        │  │ web (nginx) │  │            ┌────────────────────────────────────┐
        │  │  + SPA      │  │            │ pod: game+hub (shared netns)       │
        │  └──────┬──────┘  │            │  ┌──────────┐ ┌──────┐ ┌─────────┐ │
        │         │ proxies │            │  │ hub      │ │server│ │ playit  │ │
        │  ┌──────▼──────┐  │  register  │  │ (lobby)  │ │ (DM) │ │ agent   │ │
        │  │  API (.NET) │◄─┼────────────┤  └────┬─────┘ └──────┘ └─────────┘ │
        │  └──────┬──────┘  │  heartbeat │       │ spawns                      │
        │         │         │            │   match instances (child procs)     │
        │  ┌──────▼──────┐  │            └────────────────────────────────────┘
        │  │  MongoDB    │  │
        │  └─────────────┘  │            ┌─────────────┐
        │                   │            │ XMPP        │  presence / party / chat
        │                   │◄───────────┤ (ejabberd)  │  extauth → /oauth/verify
        └───────────────────┘  verify    └─────────────┘
```

**Components** (all in namespace `ut4-dev` in the reference deployment):

| Component | What it is | Public? |
|---|---|---|
| `ut4-mongo` | MongoDB 7 — account + server-registration data | No (in-cluster only) |
| `ut4-api` | .NET master-server API (accounts, OAuth, server browser, `/ut/api/logs`) | Via HTTPS reverse proxy |
| `ut4-web` | Vue/Vite SPA on nginx; **also reverse-proxies API paths** so SPA + API share one origin | Yes (HTTPS) |
| `ut4-xmpp` | ejabberd presence/party/chat; validating extauth against the master | Optional (raw TCP) |
| `ut4-server-58` | One pod hosting a **hub**, a **dedicated match server**, and the **playit agent** | Yes (UDP via tunnel) |

The hub and dedicated server share a pod **on purpose**: the playit agent forwards
each tunnel to `127.0.0.1`, so everything it fronts must live on the **same pod's
loopback / network namespace**. Match instances the hub spawns are child processes of
the hub container, so they inherit that same netns and their ports are reachable
through the same tunnel.

---

## 2. Prerequisites

- A **Kubernetes cluster** (any distro; the reference runs Talos). `kubectl` access.
  Everything also works with plain `kubectl apply -f` if you don't use Flux.
- **Flux** *(optional)* if you want GitOps reconciliation — see
  [§12](#12-flux--gitops-wiring).
- A **default StorageClass** for the Mongo PVC. The examples use `ceph-block`; change
  it to whatever your cluster provides (`local-path`, `longhorn`, an EBS/PD class, …).
- A **way to expose UDP publicly**. Cloudflare's tunnel is **HTTP-only** and cannot
  carry UDP game traffic, so this guide uses **[playit.gg](https://playit.gg)** (free
  TCP/UDP tunnels). A plain public IP + router port-forward works too.
- A **hostname** for the master server (`<YOUR_MASTER_HOST>`, e.g. `ut4.example.com`)
  with TLS — the reference terminates TLS at Cloudflare and routes the HTTPS origin to
  the `ut4-web` Service through a Cloudflare tunnel. Any ingress + cert-manager combo
  works equally well.

---

## 3. Container images

| Image | Role | Source |
|---|---|---|
| `ghcr.io/ut4-hub/master-server-api:<TAG>` | .NET master API | UT4MasterServer project |
| `ghcr.io/ut4-hub/master-server-web:<TAG>` | SPA + nginx | UT4MasterServer project |
| `ghcr.io/ut4-hub/ut4ms-xmpp:<TAG>` | ejabberd + extauth | UT4MasterServer project |
| `ghcr.io/itpick/ut4-install:server-linux-5.8` | UE5.8 dedicated server / hub (same build serves both) | this repo |
| `mongo:7` | database | Docker Hub |
| `ghcr.io/playit-cloud/playit-agent:1.0` | tunnel agent | playit.gg |

> The `master-server-*` images are a **reimplementation of Epic's pre-alpha UT4
> backend**. Pin a specific `<TAG>` (a digest is better) rather than `latest` so
> reconciles are reproducible. If those images are private to you, you'll need an
> image-pull secret (below).

---

## 4. Namespace & secrets

### Namespace

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ut4-dev
  labels:
    app.kubernetes.io/part-of: ut4-master-server
    environment: dev
```

### Image-pull secret (only if your images are private)

```bash
kubectl create secret docker-registry ut4-registry \
  --namespace ut4-dev \
  --docker-server=ghcr.io \
  --docker-username=<GH_USERNAME> \
  --docker-password=<GH_TOKEN>          # a PAT with read:packages
```

Every Deployment below references it via `imagePullSecrets: [{ name: ut4-registry }]`.
Drop that line if all your images are public.

### Secrets (SOPS / sealed-secrets)

In GitOps you **must not** commit that secret in plaintext. The reference repo
encrypts it with **[SOPS](https://github.com/getsops/sops) + age** so the encrypted
file is safe to commit and Flux decrypts it in-cluster. See
[Secrets](#secrets-sops--sealed-secrets) at the bottom. The two secrets you'll create:

| Secret | Keys | Used by |
|---|---|---|
| `ut4-registry` | `.dockerconfigjson` | image pulls (if private) |
| `ut4-playit-secret` | `SECRET_KEY` | the playit agent (§9) |

---

## 5. Master server (API + MongoDB + web)

### 5a. MongoDB

Single replica, **in-cluster only** (headless Service, never exposed), data on a PVC.
This is a disposable dev-scale setup — for anything serious add auth and backups.

```yaml
# mongo.yaml
apiVersion: v1
kind: Service
metadata:
  name: ut4-mongo
  namespace: ut4-dev
  labels: { app: ut4-mongo }
spec:
  clusterIP: None            # headless; reachable only in-cluster
  ports:
    - { port: 27017, targetPort: 27017, name: mongo }
  selector: { app: ut4-mongo }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ut4-mongo
  namespace: ut4-dev
  labels: { app: ut4-mongo }
spec:
  serviceName: ut4-mongo
  replicas: 1
  selector: { matchLabels: { app: ut4-mongo } }
  template:
    metadata: { labels: { app: ut4-mongo } }
    spec:
      containers:
        - name: mongo
          image: mongo:7
          args: ["--bind_ip_all"]
          ports: [{ containerPort: 27017, name: mongo }]
          volumeMounts: [{ name: data, mountPath: /data/db }]
          resources:
            requests: { memory: 256Mi, cpu: 100m }
            limits:   { memory: 1Gi,   cpu: 1000m }
          livenessProbe:
            tcpSocket: { port: 27017 }
            initialDelaySeconds: 15
            periodSeconds: 30
          readinessProbe:
            exec: { command: ["mongosh","--quiet","--eval","db.adminCommand('ping')"] }
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ceph-block        # ← change to your StorageClass
        resources: { requests: { storage: 5Gi } }
```

> **The Mongo PVC is precious.** Besides accounts, it holds the `trustedservers`
> collection that makes the address override work ([§10](#10-the-address-override-chain-the-important-gotcha)).
> That doc is **runtime data, not in git** — wipe the PVC and the override silently
> breaks (servers re-list their pod IP). Back it up.

### 5b. API (.NET)

Runs in the **Development** ASP.NET environment on purpose: Production mode requires
reCAPTCHA keys (the app throws without them). Because the web tier proxies the API on
the same origin, the dev CORS policy never engages.

```yaml
# api.yaml
apiVersion: v1
kind: Service
metadata:
  name: ut4-api
  namespace: ut4-dev
  labels: { app: ut4-api }
spec:
  type: ClusterIP
  ports: [{ port: 80, targetPort: 80, name: http }]
  selector: { app: ut4-api }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ut4-api
  namespace: ut4-dev
  labels: { app: ut4-api }
spec:
  replicas: 1
  selector: { matchLabels: { app: ut4-api } }
  template:
    metadata: { labels: { app: ut4-api } }
    spec:
      imagePullSecrets: [{ name: ut4-registry }]   # drop if image is public
      containers:
        - name: api
          image: ghcr.io/ut4-hub/master-server-api:<TAG>
          env:
            - { name: ASPNETCORE_ENVIRONMENT, value: "Development" }
            - { name: ASPNETCORE_URLS, value: "http://0.0.0.0:80" }
            - { name: ApplicationSettings__DatabaseConnectionString,
                value: "mongodb://ut4-mongo.ut4-dev.svc.cluster.local:27017" }
            - { name: ApplicationSettings__DatabaseName, value: "ut4master" }
            - { name: ApplicationSettings__AllowPasswordGrantType, value: "true" }
            # dev: log verification/reset mails to stdout instead of needing SMTP
            - { name: ApplicationSettings__Mail__LogToConsole, value: "true" }
            - { name: ApplicationSettings__Mail__FromName,    value: "UT4 Master Server" }
            - { name: ApplicationSettings__Mail__FromAddress, value: "noreply@<YOUR_MASTER_HOST>" }
            # ── address-override support (see §10) ──────────────────────────
            - { name: Trusted__AllowDeclaredAddress, value: "true" }
            # optional static egress→ingress map for a server that can't declare
            # its own address (e.g. the legacy 4.15 binary):
            # - { name: Trusted__AddressOverrides__<CLUSTER_EGRESS_IP>, value: "<PUBLIC_IP>" }
          ports: [{ containerPort: 80, name: http }]
          resources:
            requests: { memory: 256Mi, cpu: 100m }
            limits:   { memory: 512Mi, cpu: 1000m }
          livenessProbe:  { tcpSocket: { port: 80 }, initialDelaySeconds: 20, periodSeconds: 30 }
          readinessProbe: { tcpSocket: { port: 80 }, initialDelaySeconds: 10, periodSeconds: 10 }
```

The API **self-seeds** its default OAuth clients and cloud-storage system files on
first boot (`ApplicationStartupService`), so web login works with no manual bootstrap.

### 5c. Web (SPA + reverse proxy)

The SPA is built with an **empty `VITE_API_URL`** so it makes relative API calls; the
nginx in front routes the API path prefixes to `ut4-api`, giving SPA + API one origin.

```yaml
# web.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ut4-web-nginx
  namespace: ut4-dev
  annotations:
    # nginx config uses $-variables; if you run Flux with postBuild envsubst,
    # disable it on this ConfigMap so $host/$request_uri survive.
    kustomize.toolkit.fluxcd.io/substitute: disabled
data:
  nginx.conf: |
    worker_processes auto;
    pid /tmp/nginx.pid;
    events { worker_connections 1024; }
    http {
      proxy_temp_path /tmp/proxy_temp; client_body_temp_path /tmp/client_temp;
      fastcgi_temp_path /tmp/fastcgi_temp; uwsgi_temp_path /tmp/uwsgi_temp;
      scgi_temp_path /tmp/scgi_temp;
      include /etc/nginx/mime.types;
      default_type application/octet-stream;
      sendfile on; keepalive_timeout 65; gzip on;
      # your cluster DNS, so the api upstream resolves at request time
      resolver <KUBE_DNS_IP> valid=10s ipv6=off;
      server {
        listen 8080;
        server_name _;
        root /usr/share/nginx/html;
        index index.html;
        # API prefixes → .NET api Service (same origin). Case-sensitive: SPA
        # client routes are capitalized and fall through to index.html.
        location ~ ^/(account|persona|friends|entitlement|ut|admin|api)(/|$) {
          set $api_upstream ut4-api.ut4-dev.svc.cluster.local;
          proxy_pass http://$api_upstream:80$request_uri;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_read_timeout 120s;
        }
        location / { try_files $uri $uri/ /index.html; }
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: ut4-web
  namespace: ut4-dev
  labels: { app: ut4-web }
spec:
  type: ClusterIP
  ports: [{ port: 8080, targetPort: 8080, name: http }]
  selector: { app: ut4-web }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ut4-web
  namespace: ut4-dev
  labels: { app: ut4-web }
spec:
  replicas: 1
  selector: { matchLabels: { app: ut4-web } }
  template:
    metadata: { labels: { app: ut4-web } }
    spec:
      imagePullSecrets: [{ name: ut4-registry }]
      containers:
        - name: web
          image: ghcr.io/ut4-hub/master-server-web:<TAG>
          ports: [{ containerPort: 8080, name: http }]
          volumeMounts:
            - { name: nginx-conf, mountPath: /etc/nginx/nginx.conf, subPath: nginx.conf }
          resources:
            requests: { memory: 32Mi,  cpu: 25m }
            limits:   { memory: 128Mi, cpu: 200m }
          livenessProbe:  { httpGet: { path: /, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 15 }
          readinessProbe: { httpGet: { path: /, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
      volumes:
        - name: nginx-conf
          configMap: { name: ut4-web-nginx }
```

### 5d. Expose the master over HTTPS

Point `https://<YOUR_MASTER_HOST>` at the `ut4-web` Service (port 8080). Use whatever
you already run:

- **Cloudflare tunnel** (reference setup): an ingress rule sending the hostname to
  `http://ut4-web.ut4-dev.svc.cluster.local:8080`. Cloudflare provides edge TLS. This
  is fine for HTTP; it does **not** carry the UDP game traffic (that's playit, §9).
- **Ingress + cert-manager**: a standard `Ingress`/`HTTPRoute` to the `ut4-web`
  Service with a Let's Encrypt cert.

### How clients point at your master

The UE5.8 client resolves the master from its online config. In short: it reads
`MasterServerOverride` from `GameUserSettings.ini` first, then the
`[OnlineSubsystemMcp.*] Domain` sections in `Engine.ini`, then falls back to
`127.0.0.1:5000`. Set your host there so the client talks to your master. (The stock
2017 client instead **DNS-hijacks** the hardcoded Epic hostnames — see the XMPP notes.)

---

## 6. XMPP presence service (optional)

Presence / friends / party / chat run over **XMPP (ejabberd)**. You can skip this and
still have working login + server browser + join; you lose the social layer.

**Security note:** the upstream smoke-stack ships a "yes-man" extauth that accepts
*every* credential — never use it publicly. The reference replaces it with a
**validating** `extauth.py` that checks the XMPP password (which is the client's MCP
access token) against the master's `GET /account/api/oauth/verify`. No live session →
auth denied.

**Exposure caveat:** raw XMPP is TCP, **not** HTTP, so it cannot traverse a Cloudflare
HTTP tunnel on any port. Two real options:

1. **playit TCP tunnel** — a dedicated playit agent (own secret) forwarding
   `127.0.0.1:<C2S_PORT>` (co-located sidecar, same pattern as the game server).
2. **NodePort + DNS-only A record** — expose c2s on a NodePort, port-forward it on the
   router, add a **grey-cloud (not proxied)** DNS record.

Either way the stock client reaches XMPP by DNS-hijacking the hardcoded Epic host
(`prod.ol.epicgames.com`) to your endpoint; the self-signed cert's SANs must cover it.

The full manifest is large; the essential pieces are a ConfigMap with `ejabberd.yml`
(external auth, c2s/s2s/http listeners, a `cert-gen` initContainer producing a
self-signed cert with the Epic-host SANs), a ConfigMap with the validating
`extauth.py`, ClusterIP + NodePort Services, and a Deployment with the ejabberd
container plus (optionally) a playit sidecar. Key env on the ejabberd container:

```yaml
env:
  - name: MASTER_VERIFY_URL
    value: "http://ut4-api.ut4-dev.svc.cluster.local:80/account/api/oauth/verify"
  - name: XMPP_REQUIRE_JID_MATCH
    value: "false"   # flip to "true" once you confirm the JID↔account format
```

> **TODO / confirm for your setup:** the ejabberd `hosts:` vhost must match the XMPP
> domain in the client's JID (the reference lists `<YOUR_MASTER_HOST>` + `localhost`);
> and you must decide the inbound path (playit TCP vs NodePort). Until one is wired,
> XMPP is ClusterIP-only and nothing is publicly reachable.

---

## 7. Dedicated match server

A single always-on match (e.g. Deathmatch on one map). The distribution image
(`ghcr.io/itpick/ut4-install:server-linux-5.8`, same build for server and hub) has a
baked entrypoint driven by env vars. It registers with your master and is joinable
through a playit UDP tunnel.

Here we run it **as a container in the same pod as the hub and the playit agent** (see
§9 for why). If you're running a plain dedicated server with a public IP and no hub,
you can run it standalone and just open the UDP ports.

```yaml
# a container inside the ut4-server-58 pod (full pod spec in §8)
- name: server
  image: ghcr.io/itpick/ut4-install:server-linux-5.8
  imagePullPolicy: Always
  securityContext:
    allowPrivilegeEscalation: false
    capabilities: { drop: [ALL] }
    seccompProfile: { type: RuntimeDefault }
  env:
    - { name: MASTER_HOST,    value: ut4-api.ut4-dev.svc.cluster.local }  # in-cluster, XFF rides intact
    - { name: MASTER_PROTO,   value: http }
    - { name: SERVER_ADDRESS, value: "<PUBLIC_IP>" }   # advertised public (playit) IP — §10
    - { name: PORT,           value: "1245" }          # game (UDP)
    - { name: BEACON_PORT,    value: "1247" }          # query/party beacon (UDP)
    - { name: MAP,            value: DM-Outpost23 }
    - { name: GAME_MODE,      value: /Script/UnrealTournament.UTDMGameMode }
    - { name: BOT_FILL,       value: "2" }
  ports:
    - { containerPort: 1245, protocol: UDP, name: game }
    - { containerPort: 1247, protocol: UDP, name: beacon }
  resources:
    requests: { memory: 1Gi, cpu: 500m }
    limits:   { memory: 6Gi, cpu: "4" }
```

The entrypoint bakes these into `Saved/Config/LinuxServer/Engine.ini`:

- `[OnlineSubsystemMcp.AccountServiceMcp]` / `[...GameServiceMcp]` `Domain=$MASTER_HOST`,
  `Protocol=$MASTER_PROTO` → the online shim calls the master **in-cluster** directly
  (no public round-trip; the `X-Forwarded-For` header used for the address override
  rides intact).
- `[OnlineSubsystemUT] ServerAddressOverride=$SERVER_ADDRESS` → advertised public addr.
- `[/Script/OnlineSubsystemUtils.OnlineBeaconHost] ListenPort=$BEACON_PORT`.

> **Point the server at the master *in-cluster*** (the `.svc.cluster.local` name), not
> at the public `https://<HOST>`. Going through the public HTTPS edge would strip or
> rewrite the `X-Forwarded-For` header the override depends on.

---

## 8. Hub (lobby)

A **hub** boots the `UT-Entry` lobby level in `UTLobbyGameMode`. Players join the hub,
pick a match, and the hub **spawns a dedicated match instance** as a child process.
Each instance needs its own game port **and** its own query beacon, and — critically —
those ports must fall **inside the playit tunnel range** and advertise the **public**
address, or clients can't reach the instance they just started.

The stock lobby defaults (`StartingInstancePort=8000`, `InstancePortStep=10`,
`MaxInstances=16`, instance beacon `7787`) are **way outside** a small tunnel range, so
we override them. The baked entrypoint only writes `Engine.ini`, not the lobby
`Game.ini`, so the hub container runs a small **launcher script** (mounted from a
ConfigMap) that writes both.

### 8a. Launcher ConfigMap

```yaml
# hub-launch.configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ut4-hub-launch
  namespace: ut4-dev
data:
  hub-launch.sh: |
    #!/usr/bin/env bash
    set -euo pipefail
    GAME_ROOT=/server
    CFG_DIR="$GAME_ROOT/UnrealTournament/Saved/Config/LinuxServer"
    mkdir -p "$CFG_DIR"

    MASTER_HOST="${MASTER_HOST:-ut4-api.ut4-dev.svc.cluster.local}"
    MASTER_PROTO="${MASTER_PROTO:-http}"
    SERVER_ADDRESS="${SERVER_ADDRESS:-<PUBLIC_IP>}"
    PORT="${PORT:-1249}"                                  # hub game port (UDP)
    BEACON_PORT="${BEACON_PORT:-1250}"                    # hub party/reservation beacon
    GAME_MODE="${GAME_MODE:-/Script/UnrealTournament.UTLobbyGameMode}"
    STARTING_INSTANCE_PORT="${STARTING_INSTANCE_PORT:-1252}"
    INSTANCE_PORT_STEP="${INSTANCE_PORT_STEP:-1}"
    MAX_INSTANCES="${MAX_INSTANCES:-2}"
    STARTING_INSTANCE_BEACON_PORT="${STARTING_INSTANCE_BEACON_PORT:-1254}"
    INSTANCE_BEACON_PORT_STEP="${INSTANCE_BEACON_PORT_STEP:-1}"

    # Engine.ini: master domain, advertised address, hub beacon port.
    cat > "$CFG_DIR/Engine.ini" <<EOF
    [OnlineSubsystemMcp.AccountServiceMcp]
    Domain=$MASTER_HOST
    Protocol=$MASTER_PROTO

    [OnlineSubsystemMcp.GameServiceMcp]
    Domain=$MASTER_HOST
    Protocol=$MASTER_PROTO

    [OnlineSubsystemUT]
    ServerAddressOverride=$SERVER_ADDRESS

    [/Script/OnlineSubsystemUtils.OnlineBeaconHost]
    ListenPort=$BEACON_PORT
    EOF

    # Game.ini: keep spawned instance ports inside the tunnel range.
    cat > "$CFG_DIR/Game.ini" <<EOF
    [/Script/UnrealTournament.UTLobbyGameMode]
    StartingInstancePort=$STARTING_INSTANCE_PORT
    InstancePortStep=$INSTANCE_PORT_STEP
    MaxInstances=$MAX_INSTANCES
    StartingInstanceBeaconPort=$STARTING_INSTANCE_BEACON_PORT
    InstanceBeaconPortStep=$INSTANCE_BEACON_PORT_STEP
    EOF

    cd "$GAME_ROOT"
    # IMPORTANT: brace-less $GAME_MODE / $MAX_INSTANCES here — see the Flux gotcha
    # in §13. The map URL must keep its Game=… or the lobby never registers.
    exec ./UnrealTournament/Binaries/Linux/UnrealTournamentServer UnrealTournament \
      "UT-Entry?Game=$GAME_MODE?MaxInstances=$MAX_INSTANCES" \
      -port="$PORT" \
      "-ini:Engine:[OnlineSubsystemMcp.AccountServiceMcp]:Domain=$MASTER_HOST" \
      "-ini:Engine:[OnlineSubsystemMcp.GameServiceMcp]:Domain=$MASTER_HOST" \
      "-ini:Engine:[OnlineSubsystemUT]:ServerAddressOverride=$SERVER_ADDRESS" \
      -log -stdout -NoLogTimes -unattended -nosound
```

> **How instance ports are computed.** The lobby assigns
> `InstancePort = StartingInstancePort + InstancePortStep × (#running instances)`, and
> the same pattern for the per-instance beacon. With game `start=1252 step=1 max=2` you
> get instance games `1252,1253` and beacons `1254,1255`. Sized so **hub game 1249 +
> hub beacon 1250 + 2 instances (games 1252-1253, beacons 1254-1255)** all fit an
> 8-port tunnel `1249-1256`.
>
> **Two beacons, don't confuse them.** Use the `[…OnlineBeaconHost] ListenPort` ini key
> for the query beacon — **not** the `-BeaconPort=` switch, which is global and would
> collide the query beacon with the lobby control beacon. The **hub↔instance control
> beacon** (`14000`) is intra-pod loopback only — instances are child procs in the same
> netns and dial `127.0.0.1:14000` — so it needs **no** tunnel port; leave it default
> and don't expose it.

### 8b. The full pod (hub + server + playit agent)

```yaml
# server-58.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ut4-server-58
  namespace: ut4-dev
  labels: { app: ut4-server-58, role: hub-and-server, engine: ue5.8 }
spec:
  replicas: 1
  selector: { matchLabels: { app: ut4-server-58 } }
  strategy: { type: Recreate }   # single playit-secret holder; never overlap two agents
  template:
    metadata: { labels: { app: ut4-server-58, role: hub-and-server, engine: ue5.8 } }
    spec:
      imagePullSecrets: [{ name: ut4-registry }]
      securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true }
      containers:
        # ── HUB (lobby) ─────────────────────────────────────────────────────
        - name: hub
          image: ghcr.io/itpick/ut4-install:server-linux-5.8
          imagePullPolicy: Always
          command: ["/usr/bin/env", "bash", "/config/hub-launch.sh"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
          env:
            - { name: MASTER_HOST,    value: ut4-api.ut4-dev.svc.cluster.local }
            - { name: MASTER_PROTO,   value: http }
            - { name: SERVER_ADDRESS, value: "<PUBLIC_IP>" }
            - { name: PORT,           value: "1249" }   # hub game (UDP)
            - { name: BEACON_PORT,    value: "1250" }   # hub party/reservation beacon
            - { name: GAME_MODE,      value: /Script/UnrealTournament.UTLobbyGameMode }
            - { name: STARTING_INSTANCE_PORT,        value: "1252" }
            - { name: INSTANCE_PORT_STEP,            value: "1" }
            - { name: MAX_INSTANCES,                 value: "2" }
            - { name: STARTING_INSTANCE_BEACON_PORT, value: "1254" }
            - { name: INSTANCE_BEACON_PORT_STEP,     value: "1" }
          ports:
            - { containerPort: 1249, protocol: UDP, name: hub-game }
            - { containerPort: 1250, protocol: UDP, name: hub-beacon }
            - { containerPort: 1252, protocol: UDP, name: inst0-game }
            - { containerPort: 1253, protocol: UDP, name: inst1-game }
            - { containerPort: 1254, protocol: UDP, name: inst0-beacon }
            - { containerPort: 1255, protocol: UDP, name: inst1-beacon }
          volumeMounts:
            - { name: hub-launch, mountPath: /config, readOnly: true }
          resources:
            requests: { memory: 1Gi, cpu: 500m }
            limits:   { memory: 8Gi, cpu: "4" }   # headroom for match instances
        # ── SERVER (single DM match) ────────────────────────────────────────
        - name: server
          image: ghcr.io/itpick/ut4-install:server-linux-5.8
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
          env:
            - { name: MASTER_HOST,    value: ut4-api.ut4-dev.svc.cluster.local }
            - { name: MASTER_PROTO,   value: http }
            - { name: SERVER_ADDRESS, value: "<PUBLIC_IP>" }
            - { name: PORT,           value: "1245" }
            - { name: BEACON_PORT,    value: "1247" }
            - { name: MAP,            value: DM-Outpost23 }
            - { name: GAME_MODE,      value: /Script/UnrealTournament.UTDMGameMode }
            - { name: BOT_FILL,       value: "2" }
          ports:
            - { containerPort: 1245, protocol: UDP, name: game }
            - { containerPort: 1247, protocol: UDP, name: beacon }
          resources:
            requests: { memory: 1Gi, cpu: 500m }
            limits:   { memory: 6Gi, cpu: "4" }
        # ── playit agent (one agent, both tunnels → this pod's localhost) ───
        - name: playit
          image: ghcr.io/playit-cloud/playit-agent:1.0
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
          env:
            - name: SECRET_KEY
              valueFrom: { secretKeyRef: { name: ut4-playit-secret, key: SECRET_KEY } }
          volumeMounts:
            - { name: playit-run, mountPath: /run/playit }  # writable runtime dir; agent crashes without it
          resources:
            requests: { memory: 32Mi,  cpu: 10m }
            limits:   { memory: 128Mi, cpu: 500m }
      volumes:
        - { name: playit-run, emptyDir: {} }
        - name: hub-launch
          configMap: { name: ut4-hub-launch, defaultMode: 0555 }
```

**Why one pod, three containers?** The playit agent forwards each tunnel to
`127.0.0.1`, so the game server, hub, and their spawned instances must share the pod's
network namespace. `strategy: Recreate` ensures the single agent (one playit secret =
one agent) is never doubled during a rollout.

---

## 9. Public networking with playit.gg

Cloudflare's tunnel is **HTTP-only** and terminates/HTTP-parses everything — it cannot
carry UDP game traffic. So the game ports go through **[playit.gg](https://playit.gg)**,
a free TCP/UDP tunnel. Each agent forwards its tunnels to the **loopback of the pod it
runs in** — hence the one-pod-three-containers layout.

### One-time playit setup (out of band, in the playit web account)

1. Create an **agent** → it yields a `SECRET_KEY`.
2. Add a **UDP tunnel** (or a small range) on that agent, pointing its local port(s) at
   the game/beacon ports (e.g. a `1245-1248` range → `127.0.0.1:1245-1248`, and a
   `1249-1256` range → `127.0.0.1:1249-1256`). playit gives you a **public IP:port**
   (`<PUBLIC_IP>:<PORT>`) that maps 1:1 to those local ports.
3. Store the key as the `ut4-playit-secret` Secret (key `SECRET_KEY`), SOPS-encrypted.

```yaml
# playit-secret.enc.yaml — SOPS-ENCRYPT before committing (see Secrets)
apiVersion: v1
kind: Secret
metadata:
  name: ut4-playit-secret
  namespace: ut4-dev
type: Opaque
stringData:
  SECRET_KEY: "<PLAYIT_SECRET_KEY>"
```

> **One secret = one agent.** A single playit secret can't run two agents. If you also
> expose XMPP over playit ([§6](#6-xmpp-presence-service-optional)), create a **second**
> agent/secret (`ut4-playit-secret-xmpp`) for it.
>
> **`/run/playit` must be writable** — the agent crashes without it. That's the
> `emptyDir` mount above.

Whatever `<PUBLIC_IP>:<PORT>` playit assigns is what you put in `SERVER_ADDRESS` and
what players connect to. Keep the tunnel's local ports aligned with the `PORT`,
`BEACON_PORT`, and instance-port ranges above.

---

## 10. The address-override chain (the important gotcha)

**The problem.** A server behind NAT / a tunnel sees itself as a **pod IP** (or a
shared cluster egress IP). If it registers *that* with the master, the address in the
server browser is unreachable and nobody can join. It must advertise the **public
playit address** instead.

This took a master-side code change + a config flag + a runtime DB doc to solve.
**All three are required:**

1. **Server declares its address.** The UE5.8 `OnlineSubsystemUT` shim reads
   `[OnlineSubsystemUT] ServerAddressOverride` and sends it as an **`X-Forwarded-For`
   header** on its registration POST (not in the request body). That's why
   `SERVER_ADDRESS=<PUBLIC_IP>` is set on every container above, and why the server
   talks to the master **in-cluster** (a public HTTPS hop would rewrite/strip XFF).

2. **Master honors declared addresses.** `Trusted__AllowDeclaredAddress=true` on the
   API (§5b). When the request body has no `serverAddress`, the master falls back to
   the left-most `X-Forwarded-For` entry — **but only for a server whose OAuth client
   is trusted** (next point).

3. **Trust the server's client in Mongo.** Add a document to the `trustedservers`
   collection for the server's OAuth client id, at **Epic trust level (`0`)**:

   ```js
   // mongosh, against the ut4master DB
   db.trustedservers.insertOne({
     _id: "<SERVERINSTANCE_CLIENT_ID>",   // the ServerInstance OAuth client id
     TrustLevel: 0                          // 0 = Epic, 1 = Trusted, 2 = Untrusted
   })
   ```

   > **Why Epic (0), not Trusted (1)?** The enum is `Epic=0, Trusted=1, Untrusted=2`
   > (Untrusted is the *high* number). Trusted(1) triggers a name check
   > (`ServerName == client.Name`) that rejects with HTTP 400. Epic(0) **skips** that
   > check and still passes the `trust != Untrusted` gate on the override branch. An
   > unknown client defaults to Untrusted(2), so without this doc the override silently
   > does nothing and the server re-lists its pod IP.

   **This doc lives in the Mongo PVC, not in git.** If the PVC is wiped, re-insert it or
   the override breaks silently.

**Static fallback for servers that can't declare an address** (e.g. a legacy 4.15
binary): map its egress IP to the public IP on the API instead —
`Trusted__AddressOverrides__<CLUSTER_EGRESS_IP>=<PUBLIC_IP>` (commented in §5b).

> The master's `GetClientIP` does **not** unwind `X-Forwarded-For` by default (no
> `ProxyClientIPHeader` set), which is exactly why the override reads XFF directly in
> the declared-address branch. Trusting ephemeral pod IPs via `ProxyServers` is a dead
> end — `IsTrustedMachine` is exact-IP match only, no CIDR.

---

## 11. Verification

**1. Master is up.** Open `https://<YOUR_MASTER_HOST>` — the SPA loads, you can
register/login. API sanity from in-cluster:

```bash
kubectl -n ut4-dev exec deploy/ut4-web -- \
  wget -qO- http://ut4-api.ut4-dev.svc.cluster.local/account/api/oauth/verify
# 401 without a token is expected — it proves the API is reachable.
```

**2. Servers registered at the *public* address.** Check Mongo — this is the
go/no-go for the override:

```bash
kubectl -n ut4-dev exec -it ut4-mongo-0 -- mongosh ut4master --quiet --eval '
  db.servers.find({}, {ServerAddress:1, ServerPort:1, BEACONPORT_i:1, _id:0}).toArray()'
# Expect ServerAddress = <PUBLIC_IP> (NOT a 10.x/172.x pod IP), the right ports,
# and a fresh heartbeat. Hub shows mode UTLobbyGameMode.
```

If `ServerAddress` is a pod IP, the [override chain](#10-the-address-override-chain-the-important-gotcha)
is incomplete — usually the missing `trustedservers` doc.

**3. Ports are listening.**

```bash
kubectl -n ut4-dev logs deploy/ut4-server-58 -c hub    | grep -i "registered with master\|listening"
kubectl -n ut4-dev logs deploy/ut4-server-58 -c server | grep -i "registered with master"
```

**4. A client can join.** In the client (pointed at your master), the server browser
lists your DM server and hub at `<PUBLIC_IP>`. Join the DM server directly; for the
hub, use the **lobby browse → join** path (beacon-free direct travel) — start a match
and confirm you enter the spawned instance.

> **Quickplay vs lobby-browse.** The non-ranked hub hosts only a **query** beacon, not
> a party/reservation beacon, so **quickplay matchmaking** against it won't reserve.
> Use the lobby browse→join path, or add a party beacon host to the hub (a code change,
> mirroring the ranked path).

---

## 12. Flux / GitOps wiring

If you run Flux, drop these files in a directory and reconcile them with a
`kustomization.yaml`:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - playit-secret.enc.yaml     # SOPS-encrypted
  - mongo.yaml
  - api.yaml
  - web.yaml
  - hub-launch.configmap.yaml
  - server-58.yaml
  # - xmpp/                    # optional, see §6
```

Your Flux `Kustomization` (the Flux CRD, not the kustomize file) references the Git
source, the path, decryption, and — if you use it — variable substitution:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ut4
  namespace: flux-system
spec:
  interval: 10m
  sourceRef: { kind: GitRepository, name: <YOUR_GIT_SOURCE> }
  path: ./clusters/<CLUSTER>/ut4
  prune: true
  decryption:
    provider: sops
    secretRef: { name: sops-age }   # cluster's age key for SOPS
  # postBuild:
  #   substitute: { ... }           # ⚠ see the substitution gotcha in §13
```

### Secrets (SOPS / sealed-secrets)

Encrypt any Secret **before committing**. With SOPS + age, a `.sops.yaml` creation
rule matches the encrypted files and encrypts only the `data`/`stringData` values (the
`type`/`metadata` stay plaintext so Flux can still parse the manifest):

```yaml
# .sops.yaml (repo root) — illustrative
creation_rules:
  - path_regex: clusters/.*/ut4/.*(\.enc)\.ya?ml
    encrypted_regex: ^(data|stringData)$
    key_groups:
      - age: [<CLUSTER_AGE_RECIPIENT>, <YOUR_PERSONAL_AGE_RECIPIENT>]
```

```bash
sops --encrypt --in-place clusters/<CLUSTER>/ut4/playit-secret.enc.yaml
```

Flux decrypts in-cluster using the cluster's age key (the `sops-age` secret referenced
above). **sealed-secrets** is an equally valid alternative — seal the Secret with the
controller's public key and commit the `SealedSecret`. Either way, **plaintext secrets
never touch git**.

---

## 13. Troubleshooting

**Server shows up at a pod IP (10.x / 172.x), not the public IP.**
The override chain is incomplete. Verify all three of §10: `ServerAddressOverride` set
(→ XFF), `Trusted__AllowDeclaredAddress=true`, and the `trustedservers` doc at
`TrustLevel: 0`. Also confirm the server talks to the master **in-cluster** — a public
HTTPS hop can strip/rewrite `X-Forwarded-For`.

**Hub boots but never appears in the browser (⚠ Flux gotcha).**
A Flux `Kustomization` with `postBuild.substitute` rewrites **any** `${VAR}` token in
managed manifests — and **undefined** tokens become the **empty string**. If the hub
launcher's exec line uses `Game=${GAME_MODE}`, Flux blanks it → `Game=` → `UT-Entry`
boots the default menu mode instead of the lobby → it never calls
`SetupLobbyBeacons()`/`RegisterServer()`. It hides because the *assignments* use
`${VAR:-default}` (Flux fills the default), so env vars/echo look correct — only the
bare-`${VAR}` exec arg goes empty. **Fix:** use brace-less `$GAME_MODE`/`$MAX_INSTANCES`
in the exec line (bash stops the name at `?`/`"`; Flux only rewrites braced `${...}`).
Or escape as `$${VAR}`, or annotate the resource
`kustomize.toolkit.fluxcd.io/substitute: disabled`. Same reason the nginx and extauth
ConfigMaps carry that annotation.

**Client starts a hub match but can't join the instance (beacon timeout).**
The instance is advertising a pod IP:7787 (the stock beacon default, outside the
tunnel). The launcher forwards a per-slot in-tunnel `ListenPort` + the master domain +
`ServerAddressOverride` to each instance — confirm those instance beacon ports
(`1254-1255`) are inside your tunnel range and that no stray/legacy server is
registered on the same game port at an un-overridden address.

**playit agent crashes / no tunnel.**
Ensure the writable `/run/playit` `emptyDir` is mounted, the `SECRET_KEY` secret exists
and is decrypted, and you aren't running two agents from one secret. IPv6 "Network
unreachable" ping lines are benign if the pod has no v6.

**nginx `$host` / `$request_uri` disappear.**
Flux envsubst ate them — add `kustomize.toolkit.fluxcd.io/substitute: disabled` to the
web ConfigMap (already present above).

**Mongo `trustedservers` doc lost after a PVC wipe.**
It's runtime data, not in git. Re-insert it (§10) and back the PVC up.

---

## See also

- [README → Running your own server or hub](../README.md#running-your-own-server-or-hub)
  — the quick single-binary case.
- [docs/CHANNELS.md](CHANNELS.md) — stable vs nightly build channels.
