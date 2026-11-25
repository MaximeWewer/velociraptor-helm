# Velociraptor Helm

Helm chart for [Velociraptor](https://github.com/Velocidex/velociraptor) (DFIR server), built for the
hardened distroless image of [velociraptor-docker](https://github.com/MaximeWewer/velociraptor-docker).

## Architecture

- **StatefulSet master, 1 replica**: the master owns the metadata datastore (single-writer). To scale the number of clients → **multi-frontend (master/minion)**, not `replicaCount` (see below).
- **Frontend** (port 8000, gRPC/mTLS): endpoint client communications - the only external surface (`LoadBalancer` or SSL-passthrough Ingress).
- **GUI** (port 8889): admin interface. Keep internal / VPN / authenticated Ingress.
- **Server identity**: the server config embeds the CA every agent pins, the Frontend/GUI keys and the nonces. By default the chart **generates it in-cluster once and keeps it forever** (see [Server identity lifecycle](#server-identity-lifecycle)).
- **Operational config** (ports, bind addresses, URLs, datastore, logging…): rendered from values and deep-merged onto the identity by a pinned `yq` init container.
- **Datastore**: `ReadWriteOnce` PVC mounted at `/datastore` (or an external `ReadWriteMany` PVC via `persistence.existingClaim` for NFS/EFS / multi-frontend).

## Prerequisites

- Kubernetes **>= 1.27** (>= 1.29 for `orgs`, which uses a native sidecar), Helm **3+**.
- Optional, only if you enable the matching feature:
  - nginx ingress controller started with **`--enable-ssl-passthrough`** - for `frontend.ingress`.
  - A `ReadWriteMany` StorageClass (NFS/EFS) - for `frontend.minions`.
  - **Prometheus Operator** CRDs - for `serviceMonitor.enabled`.

## Install

Nothing to generate by hand:

```sh
helm install velociraptor oci://ghcr.io/maximewewer/charts/velociraptor -n dfir --create-namespace \
  --set gui.publicUrl=https://velociraptor.example.com/app/index.html \
  --set frontend.ingress.enabled=true --set frontend.ingress.className=nginx \
  --set frontend.ingress.host=velociraptor-agents.example.com

# admin password (generated)
kubectl get secret velociraptor-admin -n dfir -o jsonpath='{.data.password}' | base64 -d
# agent config (Client.server_urls = https://velociraptor-agents.example.com/)
kubectl exec -n dfir velociraptor-0 -c velociraptor -- \
  /velociraptor --config /etc/velociraptor/server.config.yaml config client > client.config.yaml
```

`Client.server_urls` (what agents dial) is derived, first match wins: `config.server.clientServerUrls` →
`https://<frontend.ingress.host>/` → `https://<frontend.service.loadBalancerIP>:<port>/` → the in-cluster
Service DNS name (only reachable from inside the cluster).

## Server identity lifecycle

Three sources for the server config, first match wins:

| Source | When | Who owns the identity |
|---|---|---|
| `config.existingSecret` | you have a secret manager (ESO/Vault/SealedSecrets) | you |
| `config.inline` | you paste a config generated out-of-band (keep it out of git) | Helm (rendered Secret) |
| `config.bootstrap` (**default**) | anything else | the chart's PKI job |

**Bootstrap** - a `pre-install`/`pre-upgrade` hook Job (Argo CD: PreSync) running the chart's own
Velociraptor image (no shell, no extra image; program in [`files/pki.vql`](files/pki.vql)):

1. If the Secret `<fullname>-server-config` exists, it is **kept as-is - never regenerated**.
   If it is missing, the config is **imported** from `config.bootstrap.importFrom` (default
   `<fullname>-config`, i.e. a former `config.inline` Secret) or else **generated** (`config generate`).
2. The Frontend/GUI certificates are **renewed** when they expire within `renewBeforeDays`, with
   `config reissue_certs`: same CA, same private keys, same nonces.
3. The Secret is created by the Job, not rendered by the chart: **Helm never deletes it (it survives
   `helm uninstall`) and Argo CD never prunes it** (no tracking metadata, `Prune=false`).

A CronJob runs the same check daily, so certificates are renewed even if nobody upgrades the release.
The CA is valid 10 years and is never rotated automatically.

In bootstrap mode the chart always owns the operational config (`config.manageServerConfig` is forced):
a raw `config generate` binds the GUI to `127.0.0.1`, stores data under `/var/tmp` (off the PVC, on a
read-only root filesystem) and points agents at `localhost`.

> **Back up the identity Secret.** Losing it orphans every enrolled agent:
> `kubectl get secret <fullname>-server-config -o yaml > velociraptor-identity.backup.yaml`

### Certificate renewal disconnects running agents (upstream bug)

Velociraptor clients (<= 0.77.3 and `master`) freeze "now" at process start when verifying the server
certificate (`private_opts.CurrentTime` in `vql/networking/tls.go`), so a running agent **rejects any
certificate issued after it started** (`x509: certificate is valid for VelociraptorServer, not <host>`),
and it never restarts itself while the server is unreachable. Hence:

- `config.bootstrap.certificateValidityDays` defaults to **3650** (the CA lifetime): a fresh install never renews.
- An imported config with short-lived certificates *will* be renewed. Do it as a planned, zero-downtime change:
  1. renew with `--set config.bootstrap.restartOnRenew=false` (and a `renewBeforeDays` above the days left):
     the new certificate is stored, the server keeps serving the old one;
  2. restart the agents while they are still connected (hunt `Admin.Client.UpdateClientConfig` with
     `RekeyClient=N`, or your fleet tooling) - they now accept certificates issued before their start;
  3. `kubectl rollout restart statefulset/<fullname>`.

### Migrating from `config.inline`

Just remove `config.inline` (and set the operational values: `gui.publicUrl`, `frontend.ingress`…).
On that upgrade the hook Job copies `<fullname>-config` into `<fullname>-server-config` **before** Helm
deletes the old Secret: same CA, same nonce, agents keep working. Note that the datastore moves to
`persistence.mountPath` (the chart-derived `Datastore.location`).

## Initial administrator

`gui.initialAdmin` (enabled by default): an init container runs
`velociraptor user add --role administrator <username> <password>` on every master start. The password
comes from `gui.initialAdmin.existingSecret`, or is generated once by the PKI job into `<fullname>-admin`.
The Secret is the source of truth: a password changed in the GUI reverts at the next restart. With OIDC,
set `username` to the admin's identity (e-mail) - the role is granted, the password is unused.

## Orgs (multi-tenancy)

```yaml
orgs:
  items:
    - { id: O01, name: "Customer A" }
    - { id: O02, name: "Customer B" }
```

Each org has its own clients, hunts, users and client config (own nonce). `GUI.initial_orgs` is only
applied on the server's very first start and `org_create()` refuses to run offline, so the chart
reconciles orgs **through the live API**: an init container issues an in-memory API client certificate,
then a native sidecar ([`files/orgs.vql`](files/orgs.vql)) creates the missing orgs and grants
`gui.initialAdmin` the administrator role in them every `reconcilePeriodSeconds`. Orgs are never renamed
or deleted by the chart. Per-org client config (`config client --org` returns an empty nonce offline):

```sh
kubectl exec -n dfir velociraptor-0 -c velociraptor -- /velociraptor --config /etc/velociraptor/server.config.yaml \
  query --format=jsonl "SELECT _client_config FROM orgs() WHERE OrgId = 'O01'" | jq -r ._client_config > client.O01.yaml
```

## Fine-grained server config

The chart renders the operational config from values and deep-merges it onto the identity. Chart-derived fields:

| Config field | Source value |
|---|---|
| `GUI.bind_port` / `GUI.public_url` / `GUI.base_path` | `gui.containerPort` / `gui.publicUrl` / `gui.basePath` |
| `GUI.authenticator.type` (+ OIDC) | `gui.oidc.*` (else `Basic`) |
| `Frontend.bind_port` / `Frontend.hostname` | `frontend.containerPort` / `frontend.ingress.host` |
| `API.bind_address` / `hostname` / `pinned_gw_name` | `frontend.minions.enabled` |
| `Client.server_urls` | see [Install](#install) |
| `Datastore.location` / `filestore_directory` | `persistence.mountPath` |
| `Monitoring.bind_address` | `serviceMonitor.enabled` (0.0.0.0 to scrape) |
| `Logging.*` | `config.server.logging.*` |
| `defaults.artifact_definitions_directories` | `config.initializeServer`, `customArtifacts` |

Every other operational field is reachable through **raw per-section maps** using the upstream field names -
`config.server.{client,api,gui,frontend,datastore,monitoring,defaults,security,minion}` - plus top-level scalars
(`serverType`, `autocertDomain`, `autocertCertCache`, `lockdown`, `debugMode`). Precedence, low → high:
**raw section maps < chart-derived fields < `config.server.extraConfig`**. Put **no secrets** in any of them.
Reference: [server.config.yaml](https://github.com/Velocidex/velociraptor/blob/master/docs/references/server.config.yaml).

```yaml
config:
  server:
    datastore: { master_implementation: MemcacheFileDataStore, minion_implementation: RemoteFileDataStore }
    frontend:  { resources: { expected_clients: 30000 } }
    gui:       { trusted_origins: ["https://velo.example"] }
    defaults:  { hunt_expiry_hours: 168, backup_period_seconds: 86400 }
    extraConfig: {}   # ultimate override, deep-merged last
```

With `config.existingSecret` / `config.inline`, set `config.manageServerConfig=true` to get the same
behaviour; otherwise the chart only injects OIDC / `initializeServer` / `customArtifacts`, and your config
must itself bind the GUI to `0.0.0.0` and put `Datastore.location` on `persistence.mountPath` (anything
else is on the read-only root filesystem: `mkdir /var/tmp/velociraptor: read-only file system`).

## Client installers (`config.initializeServer`)

Builds the MSI/DEB/RPM installers on the server's **first** start (empty datastore), like the official
Docker image. The hardened image does not ship the `Container.InitializeServer` artifact: the chart does
(ConfigMap mounted at `/chart-artifacts`). The client binaries are downloaded from GitHub releases: with
`networkPolicy.enabled`, egress 443 is opened to `networkPolicy.toolsEgressCIDRs`.

## Multi-frontend (master/minion)

Horizontal client scaling: `frontend.minions.enabled=true` adds a `…-minion-N` StatefulSet (RemoteFileDataStore) that RPCs to the master's API. Prerequisites:

- `persistence.existingClaim` = a **ReadWriteMany** PVC (NFS/EFS) shared by master+minions (the chart fails the render otherwise).
- `config.server.datastore`: `master_implementation: MemcacheFileDataStore`, `minion_implementation: RemoteFileDataStore`; `ExtraFrontends` (one per minion, `hostname: <fullname>-minion-0..N`, `bind_port: 8000`) via `config.server.extraConfig`. `API.*` is derived. The chart starts each minion with `--node <hostname>-<bind_port>` (dash).
- Validated on 0.77.3 with NetworkPolicy enforced (Calico): an agent connected only to a minion is visible on the master. (0.76.6 had an upstream nil panic in the minion, Velocidex/velociraptor#4816 - fixed since.)

## OIDC auth (Keycloak, Google, Azure…)

```sh
kubectl create secret generic velo-oidc --from-literal=oauth_client_secret='<secret>' -n dfir
helm upgrade velociraptor . -n dfir \
  --set gui.oidc.enabled=true \
  --set gui.publicUrl=https://velociraptor.example.com/app/index.html \
  --set gui.oidc.issuer=https://keycloak.example.com/realms/dfir \
  --set gui.oidc.name=keycloak --set gui.oidc.clientId=velociraptor \
  --set gui.oidc.existingSecret=velo-oidc \
  --set gui.initialAdmin.username=admin@example.com
```

OIDC discovery is fetched at server start: with `networkPolicy.enabled`, list the IdP in `networkPolicy.oidcEgressCIDRs`.

## Server API (`api.expose`)

`api.expose.enabled` makes the master API (gRPC, mutual TLS) listen on `0.0.0.0` behind the
`<fullname>-api` Service, so API clients outside the pod (Tracecat, scripts, Grafana) can reach
it. The NetworkPolicy only admits the release's own pods and `api.expose.allowedFrom` peers.
`API.hostname` is set to the Service DNS name; clients verify the server by its pinned
certificate name (`GRPC_GW`), not by DNS. API clients authenticate with certificates signed by
the server CA (see `apiClients`).

## Extension points

- `extraObjects`: raw manifests (maps or strings) rendered through `tpl`, e.g. a responder
  Deployment or an ExternalSecret, without a new chart release.
- `extraContainers` / `extraInitContainers`: added to the master pod (through `tpl`); init
  containers run after the chart's own.
- `customArtifacts.existingConfigMaps`: several ConfigMaps (names through `tpl`) projected into
  one artifact directory with `customArtifacts.files` (file names must be unique).

## Monitoring & alerting

- `serviceMonitor.enabled`: scrapes the master **and the minions** (with multi-frontend, agents are spread over all frontends). `Monitoring.bind_address` is set to `0.0.0.0` when the chart manages the config.
- `prometheusRule.enabled` (Prometheus Operator; the `kubernetes` group needs kube-state-metrics):

| Alert | Severity | Fires when |
|---|---|---|
| `VelociraptorServerDown` | critical | no frontend answers on its metrics port for 5m |
| `VelociraptorConnectedClientsDropped` | warning | connected clients < `clientsDrop.ratio` × peak of `clientsDrop.window` (fleet ≥ `minClients`) - frontend/ingress outage, or agents rejecting renewed certificates |
| `VelociraptorFrontendLoadShedding` | warning | the frontend rejects connections for 15m |
| `VelociraptorMasterNotReady` | critical | the master is not Ready for 10m |
| `VelociraptorCertificateCheckFailing` | warning | the certificate CronJob failed / stopped succeeding (see below) |
| `VelociraptorReconcilerFailing` | warning | the API reconciler sidecar restarted at least twice in 1h (it exits after 5 failed attempts) |
| `VelociraptorIdentitySecretMissing` | critical | the identity Secret (bootstrap) disappeared - restore it before the next upgrade |

Velociraptor exports no certificate-expiry metric, so the **certificate CronJob is the probe**: in bootstrap mode it renews; with `existingSecret` / `inline` it runs **read-only** (`CheckOnly`) and fails when the server certificates expire within `renewBeforeDays` - nothing renews a config managed outside the chart. In every mode it fails when the CA expires within `config.bootstrap.caWarnDays` (180). The rules are unit-tested with `promtool` (`ci/test-alert-rules.sh`).

## Testing

- `helm test <release>`: a pod running the chart's own image checks that the frontend serves its certificate and that the GUI answers (Basic: the initial admin logs in; OIDC: anonymous API calls get 401).
- CI (`.github/workflows/test-chart.yml`): `ct lint` + render of every mode + README freshness + `promtool` rule tests; then, on kind, `ct install` of `chart/ci/*-values.yaml` (with `helm test`) and `ci/e2e.sh`.
- `ci/e2e.sh` (any cluster, current context): bootstrap, enrolled agent, idempotent upgrade, orgs, forced renewal (same CA, new certificate served), uninstall/reinstall (identity kept), read-only check failing in `existingSecret` mode, `inline` → bootstrap migration.
- Validated manually (Calico, NetworkPolicy enforced): OIDC login through Keycloak (redirect, form, callback, session), multi-frontend (agent on a minion visible on the master), GUI closed to undeclared peers, server egress limited to DNS + IdP.

## Operational pitfalls

- **StatefulSet stuck on a broken pod**: if a pod of a previous revision never became Ready, the StatefulSet does not roll it (kubernetes/kubernetes#67250). Fix the values, then `kubectl delete pod <fullname>-0`.
- **`helm uninstall` keeps** the identity Secret, the admin Secret and the PKI hook RBAC (`<fullname>-pki` ServiceAccount/Role/RoleBinding). Delete them explicitly to start from scratch.
- **NetworkPolicy**: the PKI job and `helm test` pods are not selected by the chart's policy (they need the API server / the Services); a namespace-wide default-deny egress must allow the PKI pods to reach `kubernetes.default.svc:443`.

## Main values

| Key | Default | Description |
|-----|---------|-------------|
| `image.registry` / `image.repository` | `ghcr.io` / `maximewewer/velociraptor` | Hardened distroless rebuild ([velociraptor-docker](https://github.com/MaximeWewer/velociraptor-docker)) |
| `image.tag` | `0.77.3-distroless` | Tag; prefer `image.digest` in production |
| `replicaCount` | `1` | **master** pods - **must stay 1** (single-writer datastore); scale via `frontend.minions` |
| `config.bootstrap.enabled` | `true` | Generate/keep the identity in-cluster when no `existingSecret`/`inline` |
| `config.bootstrap.certificateValidityDays` | `3650` | Server certificate validity (renewals disconnect running agents) |
| `config.bootstrap.renewBeforeDays` | `30` | Renew when a server certificate expires within N days |
| `config.bootstrap.importFrom` | `""` (`<fullname>-config`) | Secret to adopt instead of generating (migration) |
| `config.existingSecret` | `""` | Secret containing `server.config.yaml` (secret manager) |
| `config.inline` | `""` | Inline config rendered into a chart-managed Secret - keep out of git |
| `config.manageServerConfig` | `false` | Render the operational config from values (forced in bootstrap mode) |
| `config.server.clientServerUrls` | `[]` | `Client.server_urls`; empty → derived |
| `config.server.extraConfig` | `{}` | Raw YAML deep-merged last onto the rendered overlay (escape hatch) |
| `config.initializeServer` | `false` | Build MSI/DEB/RPM installers on first start (`Container.InitializeServer`, shipped by the chart) |
| `gui.initialAdmin.enabled` / `username` | `true` / `admin` | Ensure an administrator on every start |
| `gui.initialAdmin.existingSecret` | `""` | Password Secret; empty → generated into `<fullname>-admin` |
| `orgs.items` | `[]` | Declared orgs, reconciled through the API (never deleted) |
| `customArtifacts.enabled` | `false` | Mount custom VQL artifacts (ConfigMap) at `customArtifacts.path` and load them |
| `customArtifacts.existingConfigMaps` | `[]` | Extra artifact ConfigMaps projected into the same directory |
| `api.expose.enabled` / `api.expose.allowedFrom` | `false` / `[]` | Serve the API on the `<fullname>-api` Service to the declared peers |
| `extraObjects` / `extraContainers` / `extraInitContainers` | `[]` | Escape hatches (rendered through `tpl`) |
| `frontend.minions.enabled` | `false` | Multi-frontend (master/minion); requires a RWX `persistence.existingClaim` |
| `frontend.service.type` | `LoadBalancer` | Frontend exposure (endpoint clients) |
| `frontend.ingress.enabled` | `false` | SSL-passthrough Ingress for agent comms (L4 TLS by SNI; needs nginx `--enable-ssl-passthrough`) |
| `frontend.ingress.host` | `""` | Agent SNI host; distinct from the GUI host |
| `gui.ingress.enabled` | `false` | GUI Ingress (authenticated/VPN) |
| `gui.publicUrl` | `""` | `GUI.public_url` (must end with `/app/index.html`); required for OIDC |
| `gui.oidc.enabled` | `false` | OIDC auth |
| `persistence.size` | `20Gi` | Datastore size (chart-managed PVC) |
| `persistence.existingClaim` | `""` | External PVC (NFS/EFS RWX); required for multi-frontend |
| `networkPolicy.enabled` | `true` | NetworkPolicy |
| `networkPolicy.frontendAllowedCIDRs` | `[0.0.0.0/0]` | CIDRs allowed to the frontend - **restrict** |
| `serviceMonitor.enabled` | `false` | Prometheus scrape |
| `prometheusRule.enabled` | `false` | Alerting rules (server + kube-state-metrics groups) |
| `config.bootstrap.caWarnDays` | `180` | The certificate CronJob fails when the CA expires within N days |

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| api.expose.allowedFrom | list | `[]` |  |
| api.expose.enabled | bool | `false` |  |
| api.service.annotations | object | `{}` |  |
| config.bootstrap.activeDeadlineSeconds | int | `300` |  |
| config.bootstrap.caWarnDays | int | `180` |  |
| config.bootstrap.certificateValidityDays | int | `3650` |  |
| config.bootstrap.enabled | bool | `true` |  |
| config.bootstrap.importFrom | string | `""` |  |
| config.bootstrap.renewBeforeDays | int | `30` |  |
| config.bootstrap.renewal.enabled | bool | `true` |  |
| config.bootstrap.renewal.schedule | string | `"17 3 * * *"` |  |
| config.bootstrap.renewal.timeZone | string | `""` |  |
| config.bootstrap.resources.limits.memory | string | `"512Mi"` |  |
| config.bootstrap.resources.requests.cpu | string | `"100m"` |  |
| config.bootstrap.resources.requests.memory | string | `"128Mi"` |  |
| config.bootstrap.restartOnRenew | bool | `true` |  |
| config.bootstrap.secretName | string | `""` |  |
| config.existingSecret | string | `""` |  |
| config.initializeServer | bool | `false` |  |
| config.inline | string | `""` |  |
| config.manageServerConfig | bool | `false` |  |
| config.mountPath | string | `"/etc/velociraptor/server.config.yaml"` |  |
| config.overlay.image.digest | string | `"sha256:b1d117c609ba990436ad1649299e2f6c378f62cb562caf30b6f2fb6144713422"` |  |
| config.overlay.image.pullPolicy | string | `"IfNotPresent"` |  |
| config.overlay.image.repository | string | `"mikefarah/yq"` |  |
| config.overlay.image.tag | string | `"4.44.6"` |  |
| config.secretKey | string | `"server.config.yaml"` |  |
| config.server.api | object | `{}` |  |
| config.server.autocertCertCache | string | `""` |  |
| config.server.autocertDomain | string | `""` |  |
| config.server.client | object | `{}` |  |
| config.server.clientServerUrls | list | `[]` |  |
| config.server.datastore | object | `{}` |  |
| config.server.datastoreImplementation | string | `"FileBaseDataStore"` |  |
| config.server.debugMode | string | `nil` |  |
| config.server.defaults | object | `{}` |  |
| config.server.extraConfig | object | `{}` |  |
| config.server.frontend | object | `{}` |  |
| config.server.gui | object | `{}` |  |
| config.server.lockdown | string | `nil` |  |
| config.server.logging.maxAge | int | `31536000` |  |
| config.server.logging.outputDirectory | string | `""` |  |
| config.server.logging.remoteSyslogComponents | list | `[]` |  |
| config.server.logging.remoteSyslogProtocol | string | `""` |  |
| config.server.logging.remoteSyslogServer | string | `""` |  |
| config.server.logging.rotationTime | int | `604800` |  |
| config.server.logging.separateLogsPerComponent | bool | `true` |  |
| config.server.minion | object | `{}` |  |
| config.server.monitoring | object | `{}` |  |
| config.server.security | object | `{}` |  |
| config.server.serverType | string | `""` |  |
| customArtifacts.enabled | bool | `false` |  |
| customArtifacts.existingConfigMap | string | `""` |  |
| customArtifacts.existingConfigMaps | list | `[]` |  |
| customArtifacts.files | object | `{}` |  |
| customArtifacts.path | string | `"/custom_artifacts"` |  |
| extraArgs | list | `[]` |  |
| extraContainers | list | `[]` |  |
| extraEnv | list | `[]` |  |
| extraInitContainers | list | `[]` |  |
| extraObjects | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| frontend.apiPort | int | `8001` |  |
| frontend.containerPort | int | `8000` |  |
| frontend.ingress.annotations."nginx.ingress.kubernetes.io/backend-protocol" | string | `"HTTPS"` |  |
| frontend.ingress.annotations."nginx.ingress.kubernetes.io/ssl-passthrough" | string | `"true"` |  |
| frontend.ingress.className | string | `""` |  |
| frontend.ingress.enabled | bool | `false` |  |
| frontend.ingress.host | string | `""` |  |
| frontend.ingress.path | string | `"/"` |  |
| frontend.ingress.pathType | string | `"ImplementationSpecific"` |  |
| frontend.ingress.tls | list | `[]` |  |
| frontend.minions.affinity | object | `{}` |  |
| frontend.minions.enabled | bool | `false` |  |
| frontend.minions.nodeSelector | object | `{}` |  |
| frontend.minions.podAnnotations | object | `{}` |  |
| frontend.minions.replicas | int | `2` |  |
| frontend.minions.resources | object | `{}` |  |
| frontend.minions.tolerations | list | `[]` |  |
| frontend.service.annotations | object | `{}` |  |
| frontend.service.externalTrafficPolicy | string | `"Local"` |  |
| frontend.service.loadBalancerIP | string | `""` |  |
| frontend.service.loadBalancerSourceRanges | list | `[]` |  |
| frontend.service.port | int | `8000` |  |
| frontend.service.type | string | `"LoadBalancer"` |  |
| fullnameOverride | string | `""` |  |
| gui.basePath | string | `""` |  |
| gui.containerPort | int | `8889` |  |
| gui.ingress.annotations | object | `{}` |  |
| gui.ingress.className | string | `""` |  |
| gui.ingress.enabled | bool | `false` |  |
| gui.ingress.hosts[0].host | string | `"velociraptor.example.com"` |  |
| gui.ingress.hosts[0].paths[0].path | string | `"/"` |  |
| gui.ingress.hosts[0].paths[0].pathType | string | `"Prefix"` |  |
| gui.ingress.tls | list | `[]` |  |
| gui.initialAdmin.enabled | bool | `true` |  |
| gui.initialAdmin.existingSecret | string | `""` |  |
| gui.initialAdmin.passwordKey | string | `"password"` |  |
| gui.initialAdmin.username | string | `"admin"` |  |
| gui.oidc.avatar | string | `""` |  |
| gui.oidc.clientId | string | `"velociraptor"` |  |
| gui.oidc.clientSecret | string | `""` |  |
| gui.oidc.enabled | bool | `false` |  |
| gui.oidc.existingSecret | string | `""` |  |
| gui.oidc.existingSecretKey | string | `"oauth_client_secret"` |  |
| gui.oidc.issuer | string | `""` |  |
| gui.oidc.name | string | `"keycloak"` |  |
| gui.publicUrl | string | `""` |  |
| gui.service.annotations | object | `{}` |  |
| gui.service.port | int | `8889` |  |
| gui.service.type | string | `"ClusterIP"` |  |
| image.digest | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.registry | string | `"ghcr.io"` |  |
| image.repository | string | `"maximewewer/velociraptor"` |  |
| image.tag | string | `"0.77.3-distroless"` |  |
| imagePullSecrets | list | `[]` |  |
| livenessProbe.failureThreshold | int | `6` |  |
| livenessProbe.httpGet.path | string | `"/healthz"` |  |
| livenessProbe.httpGet.port | string | `"frontend"` |  |
| livenessProbe.httpGet.scheme | string | `"HTTPS"` |  |
| livenessProbe.initialDelaySeconds | int | `15` |  |
| livenessProbe.periodSeconds | int | `20` |  |
| livenessProbe.timeoutSeconds | int | `5` |  |
| monitoring.containerPort | int | `8003` |  |
| nameOverride | string | `""` |  |
| networkPolicy.enabled | bool | `true` |  |
| networkPolicy.extraEgress | list | `[]` |  |
| networkPolicy.frontendAllowedCIDRs[0] | string | `"0.0.0.0/0"` |  |
| networkPolicy.guiAllowedFrom | list | `[]` |  |
| networkPolicy.metricsAllowedFrom | list | `[]` |  |
| networkPolicy.oidcEgressCIDRs[0] | string | `"0.0.0.0/0"` |  |
| networkPolicy.oidcEgressPort | int | `443` |  |
| networkPolicy.toolsEgressCIDRs[0] | string | `"0.0.0.0/0"` |  |
| nodeSelector | object | `{}` |  |
| orgs.items | list | `[]` |  |
| orgs.reconcilePeriodSeconds | int | `60` |  |
| orgs.resources.limits.memory | string | `"192Mi"` |  |
| orgs.resources.requests.cpu | string | `"10m"` |  |
| orgs.resources.requests.memory | string | `"64Mi"` |  |
| persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| persistence.annotations | object | `{}` |  |
| persistence.enabled | bool | `true` |  |
| persistence.existingClaim | string | `""` |  |
| persistence.mountPath | string | `"/datastore"` |  |
| persistence.size | string | `"20Gi"` |  |
| persistence.storageClass | string | `""` |  |
| podAnnotations | object | `{}` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.maxUnavailable | string | `""` |  |
| podDisruptionBudget.minAvailable | string | `""` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `65532` |  |
| podSecurityContext.fsGroupChangePolicy | string | `"OnRootMismatch"` |  |
| podSecurityContext.runAsGroup | int | `65532` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.runAsUser | int | `65532` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| priorityClassName | string | `""` |  |
| prometheusRule.clientsDrop.for | string | `"15m"` |  |
| prometheusRule.clientsDrop.minClients | int | `10` |  |
| prometheusRule.clientsDrop.ratio | float | `0.5` |  |
| prometheusRule.clientsDrop.window | string | `"6h"` |  |
| prometheusRule.enabled | bool | `false` |  |
| prometheusRule.extraRules | list | `[]` |  |
| prometheusRule.kubeStateMetrics | bool | `true` |  |
| prometheusRule.labels | object | `{}` |  |
| prometheusRule.namespace | string | `""` |  |
| readinessProbe.failureThreshold | int | `6` |  |
| readinessProbe.httpGet.path | string | `"/healthz"` |  |
| readinessProbe.httpGet.port | string | `"frontend"` |  |
| readinessProbe.httpGet.scheme | string | `"HTTPS"` |  |
| readinessProbe.initialDelaySeconds | int | `10` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.timeoutSeconds | int | `5` |  |
| replicaCount | int | `1` |  |
| resources.limits.cpu | string | `"2"` |  |
| resources.limits.memory | string | `"2Gi"` |  |
| resources.requests.cpu | string | `"250m"` |  |
| resources.requests.memory | string | `"512Mi"` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.privileged | bool | `false` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsGroup | int | `65532` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `65532` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automountServiceAccountToken | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| serviceMonitor.enabled | bool | `false` |  |
| serviceMonitor.interval | string | `"30s"` |  |
| serviceMonitor.labels | object | `{}` |  |
| serviceMonitor.namespace | string | `""` |  |
| serviceMonitor.path | string | `"/metrics"` |  |
| serviceMonitor.port | string | `"metrics"` |  |
| serviceMonitor.scheme | string | `"http"` |  |
| serviceMonitor.scrapeTimeout | string | `"10s"` |  |
| terminationGracePeriodSeconds | int | `60` |  |
| tmpDir.enabled | bool | `true` |  |
| tmpDir.sizeLimit | string | `"1Gi"` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` |  |
