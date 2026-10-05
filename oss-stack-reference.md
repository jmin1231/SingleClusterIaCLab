# Local lab: open-source equivalents for an AWS cloud-security stack

Reference for building the lateral-movement / IAM lab on real open-source
engines instead of an AWS emulator. CloudStack is the IaaS substrate (plays
AWS's EC2/VPC role), Terraform provisions it, Ansible configures the VMs, and
Gitea Actions runs the pipeline.

## Architecture

```
Gitea + Actions runner        ← CI/CD (runs TF + Ansible)
        │
Terraform  → CloudStack       ← provision VMs, networks, storage  (the "cloud")
Ansible    → the VMs          ← configure OS + deploy the services below
        │
┌─────────────────────────────────────────────────────────┐
│  Platform services running on CloudStack VMs:             │
│  Keycloak · Vault · MinIO · Loki · Prometheus · Grafana   │
│  Wazuh · Falco                                            │
└─────────────────────────────────────────────────────────┘
```

## Recommended tool per AWS concept

| AWS concept | Recommended | Why this one | Alternatives |
|---|---|---|---|
| **EC2/VPC (the cloud)** | **Apache CloudStack** | Native TF provider, KVM, real networking | Proxmox+TF, OpenStack |
| **S3** | **MinIO** | S3-API, OIDC auth, its own audit log | Garage, SeaweedFS, Ceph RGW |
| **Secrets Manager + STS** | **Vault** (or **OpenBao**) | Secrets *and* the AssumeRole mechanism: auth methods = trust, policies = permissions, tokens/leases = temp creds, dynamic secrets engines mint short-lived downstream creds | Infisical (secrets only) |
| **IAM directory + federation** | **Keycloak** | De-facto OSS IdP; OIDC/SAML; realms/roles/groups; integrates with Vault, MinIO, Grafana, Gitea | Authentik (more modern UI) |
| **Host identity (optional)** | **FreeIPA** | Kerberos/SSH/sudo, host enrollment — only if you want *host-to-host* lateral movement too | — |
| **Authorization policy** | **OPA** (Rego) or **Cedar** | Policy-as-code, external decision point | native RBAC per service |
| **CloudWatch Logs / CloudTrail search** | **Loki** | Grafana-native log store; aggregate every service's audit log here | OpenSearch (heavier, better for SIEM) |
| **Log shipping agent** | **Vector** or **Grafana Alloy** | Vendor-neutral, transforms/normalizes the different audit formats | Fluent Bit, Promtail |
| **CloudWatch Alarms** | **Prometheus + Alertmanager** | Metrics + alerting | — |
| **Dashboards** | **Grafana** | Sits over Loki + Prometheus | — |
| **GuardDuty / threat detection** | **Wazuh** + **Falco** | Wazuh = SIEM (log correlation, the "identify lateral movement" engine); Falco = runtime/syscall detection | Suricata/Zeek for network |

## Notes

- **CloudTrail has no single equivalent.** Turn on each component's own audit
  log (Vault audit device, MinIO audit, Keycloak/FreeIPA events), ship them via
  Vector into Loki (or Wazuh); that aggregate *is* your CloudTrail.
- **IAM is several jobs:** Keycloak = directory + federation, Vault = the
  AssumeRole / temporary-credential mechanism, OPA/Cedar = policy evaluation.
- **Prometheus is metrics, not logs** — logs go to Loki, not Prometheus.

## CI / provisioning flow

- Repo: `terraform/` (CloudStack resources) + `ansible/` (service config); one
  pipeline runs `terraform apply` then `ansible-playbook`.
- **Two-phase bootstrap** (avoids the chicken-and-egg where TF state/secrets
  should live in MinIO/Vault, but TF is what creates them):
  - **Phase 0:** local/Gitea-hosted state provisions core VMs + MinIO + Vault + Keycloak.
  - **Phase 1:** switch Terraform to the MinIO **s3 state backend** and pull
    secrets from Vault; everything after bootstrap is stateful and reproducible.
- **CI secrets:** the runner authenticates to Vault (AppRole or Keycloak OIDC →
  Vault JWT) and pulls short-lived CloudStack/MinIO creds per run — no long-term
  keys in Gitea, which also demonstrates the principle the lab teaches.
- **Runner image:** bake Terraform, Ansible, and the cloud CLIs into a custom
  Gitea Actions runner so pipelines start fast.

## Suggested build order

1. CloudStack up, reachable by Terraform (smoke-test: TF creates one VM).
2. Gitea + runner; pipeline runs `terraform plan` against CloudStack.
3. Phase-0 services: MinIO, Vault, Keycloak via TF + Ansible.
4. Flip Terraform state to MinIO; runner auth to Vault.
5. Observability: Loki + Vector + Prometheus + Grafana.
6. Identity wiring: Keycloak → Vault (OIDC), MinIO (OIDC), Grafana, Gitea SSO.
7. Detection: Wazuh/Falco, audit-log correlation rules.
8. The exercise: vulnerable identity chain → attack → detection → hardening.
