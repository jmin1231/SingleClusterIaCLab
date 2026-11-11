# Backend cluster

What each box in `backend-k3s.drawio` is, in words.

## be-1 and its networks

be-1 is an Ubuntu 24.04 VM (4 vCPU, 6 GB) running single-node k3s. Pods get addresses
from `10.42.0.0/16`, services from `10.43.0.0/16`.

| Network | be-1 address | Used for |
|---|---|---|
| WireGuard wg1 `10.99.1.0/24` | `10.99.1.2` | Frontend requests arriving from tun-1. Only port 8000 (the gateway) is allowed. |
| mgmt network `10.250.0.0/24` | eth1 `10.250.0.112` | Talking to the host at `10.250.0.1`. In: SSH 22, k3s API 6443. Out: Vault 8200; Gitea and telemetry on 443. |

## Mesh

The **ambient mesh** (Istio) gives every meshed pod strict mTLS, carried by ztunnel. No
sidecars.

| Namespace | Part | What it does |
|---|---|---|
| ingress (outside the mesh) | Istio Gateway :8000 | The only way in from the frontend. Hands requests to the api. |
| app | api :8000 | The Flask app. Encrypts card numbers with Vault, stores them in postgres. Metrics on 9090. |
| db | postgres :5432 | Run by CloudNativePG. Clients use the service `postgres-rw`. |
| monitoring | Alloy | Scrapes metrics and collects logs, then pushes them to Prometheus and Loki on the host. |
| monitoring | kube-state-metrics | Reports the state of cluster objects as metrics. |

## Outside the mesh

| Namespace | Part | What it does |
|---|---|---|
| node-agents | alloy-audit | Reads the k3s API audit log and sends it on. |
| node-agents | node-exporter :9100 | Node metrics. Runs on the host network, so it is not meshed. |
| istio-system | istiod, ztunnel, istio-cni | The mesh control plane, the per-node mTLS tunnel, and the CNI plugin that redirects pod traffic into ztunnel. |
| flux-system | Flux | GitOps: keeps the cluster in sync with the repo in Gitea. |
| cnpg-system | CNPG operator | Creates and runs the postgres cluster. |
| vso | Vault Secrets Operator | Copies secrets from Vault KV into Kubernetes Secrets. |
