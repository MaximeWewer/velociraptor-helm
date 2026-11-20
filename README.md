# Velociraptor Helm Chart

Hardened Helm chart for [Velociraptor](https://github.com/Velocidex/velociraptor) (DFIR server) on Kubernetes.

Runs a hardened **distroless, rootless** rebuild of the server image, published from
[velociraptor-docker](https://github.com/MaximeWewer/velociraptor-docker)
(`ghcr.io/maximewewer/velociraptor`).

## Features

- **Zero manual config generation**: the server identity (CA, server keys, nonces) is generated
  in-cluster on first install, kept in a Secret that Helm never deletes and Argo CD never prunes,
  and never regenerated (every enrolled agent pins the CA).
- **Certificate lifecycle**: server certificates renewed before expiry with the same CA and keys;
  a daily check also covers configs managed outside the chart (`existingSecret` / `inline`).
- **Fine-grained server config from values**: ports, URLs, datastore, logging, monitoring, auth
  are rendered from chart values; any other field through per-section passthrough maps.
- Initial administrator with a generated password, OIDC (Keycloak/Google/Azure).
- Declarative **orgs** (multi-tenancy), reconciled through the server API.
- Client installers (MSI/DEB/RPM) built on first start (`config.initializeServer`).
- StatefulSet master + optional master/minion multi-frontend.
- Agent frontend exposed by `LoadBalancer` or SSL-passthrough Ingress; GUI by Ingress.
- NetworkPolicy, ServiceMonitor (master + minions), PrometheusRule alerts, hardened securityContext.
- Tested: `helm test`, chart-testing and an end-to-end lifecycle suite in CI.
- Automated weekly version updates tracking the published hardened image.

## Prerequisites

- Kubernetes **>= 1.27** (>= 1.29 for orgs), Helm **3+**.
- Optional: an nginx ingress controller with `--enable-ssl-passthrough` (agent Ingress), a
  `ReadWriteMany` StorageClass (multi-frontend), Prometheus Operator CRDs (ServiceMonitor,
  PrometheusRule), kube-state-metrics (Kubernetes alerts).

## Installation

### Helm (OCI)

```bash
helm install velociraptor oci://ghcr.io/maximewewer/charts/velociraptor \
  --namespace dfir --create-namespace \
  --set gui.publicUrl=https://velociraptor.example.com/app/index.html \
  --set frontend.ingress.enabled=true \
  --set frontend.ingress.className=nginx \
  --set frontend.ingress.host=velociraptor-agents.example.com

# generated admin password
kubectl get secret velociraptor-admin -n dfir -o jsonpath='{.data.password}' | base64 -d
# agent config (Client.server_urls = https://velociraptor-agents.example.com/)
kubectl exec -n dfir velociraptor-0 -c velociraptor -- \
  /velociraptor --config /etc/velociraptor/server.config.yaml config client > client.config.yaml
```

Back up the identity Secret: losing it orphans every enrolled agent.

```bash
kubectl get secret velociraptor-server-config -n dfir -o yaml > velociraptor-identity.backup.yaml
```

### From source

```bash
git clone https://github.com/MaximeWewer/velociraptor-helm.git
cd velociraptor-helm
helm install velociraptor chart/ --namespace dfir --create-namespace -f my-values.yaml
```

### Argo CD

The identity bootstrap runs as a Helm hook, which Argo CD runs as a PreSync hook.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velociraptor
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ghcr.io/maximewewer/charts
    chart: velociraptor
    targetRevision: "<chart-version>"   # pin a published version
    helm:
      releaseName: velociraptor
      values: |
        gui:
          publicUrl: https://velociraptor.example.com/app/index.html
        frontend:
          service:
            type: ClusterIP
          ingress:
            enabled: true
            className: nginx
            host: velociraptor-agents.example.com
  destination:
    server: https://kubernetes.default.svc
    namespace: dfir
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### Bring your own config

You can still provide a config generated out-of-band: `config.existingSecret` (secret manager) or
`config.inline` (keep it out of git). Removing `config.inline` later migrates it to the in-cluster
bootstrap automatically, keeping the same CA.

## Configuration

See [`chart/README.md`](chart/README.md): identity lifecycle, certificate renewal (and the upstream
client bug that makes renewals disruptive), orgs, monitoring, testing and the full list of values.

## License

This chart is distributed under the [Apache License 2.0](LICENSE). Velociraptor itself is licensed AGPL-3.0 by Velocidex.
