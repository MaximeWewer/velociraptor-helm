# Velociraptor Helm Chart

Hardened Helm chart for [Velociraptor](https://github.com/Velocidex/velociraptor) (DFIR server) on Kubernetes.

Runs a hardened **distroless, rootless** rebuild of the server image, published from
[velociraptor-docker](https://github.com/MaximeWewer/velociraptor-docker)
(`ghcr.io/maximewewer/velociraptor`).

## Features

- StatefulSet master (single-writer datastore) + optional master/minion multi-frontend
- Out-of-band server config from a Secret (CA + private keys never in values)
- Optional OIDC (Keycloak/Google/Azure) via a yq overlay-merge init-container
- Optional custom VQL artifacts + client installer build (`Container.InitializeServer`)
- NetworkPolicies (frontend gated by CIDR), ServiceMonitor, hardened securityContext
- Automated weekly version updates tracking upstream Velociraptor releases

## Prerequisites

- A Kubernetes cluster, Helm **3+**.
- A **server config** (`server.config.yaml`, embeds the CA + private keys) generated out-of-band and stored in a Secret — the chart does not template it. See [velociraptor-docker](https://github.com/MaximeWewer/velociraptor-docker).
- Optional: a `ReadWriteMany` StorageClass (multi-frontend), Prometheus Operator CRDs (ServiceMonitor).

## Installation

```bash
# 1. Generate the server config out-of-cluster, store it in a Secret
velociraptor config generate > server.config.yaml   # edit ports/URLs
kubectl create secret generic velo-config \
  --from-file=server.config.yaml=./server.config.yaml -n dfir
```

### Helm (OCI)

```bash
helm install velo oci://ghcr.io/maximewewer/charts/velociraptor \
  --namespace dfir --create-namespace \
  --set config.existingSecret=velo-config
```

### From source

```bash
git clone https://github.com/MaximeWewer/velociraptor-helm.git
cd velociraptor-helm
helm install velo chart/ \
  --namespace dfir --create-namespace \
  --set config.existingSecret=velo-config
```

### Argo CD

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
      values: |
        config:
          existingSecret: velo-config
  destination:
    server: https://kubernetes.default.svc
    namespace: dfir
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

## Configuration

See the full list of configurable values in [`chart/README.md`](chart/README.md).

## License

This chart is distributed under the [Apache License 2.0](LICENSE). Velociraptor itself is licensed AGPL-3.0 by Velocidex.
