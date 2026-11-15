# homelab-gitops

Desired state of the Proxmox K3s cluster, deployed by **Argo CD** using the app-of-apps pattern.

```
platform                      root Application (created by Ansible, see below) -> apps/platform/
└── monitoring                apps/platform/monitoring.yaml                    -> apps/platform/monitoring/
    └── kube-monitoring       apps/platform/monitoring/kube-monitoring.yaml    -> kube-monitoring-chart (Helm)
```

## How it fits together

| Layer | Repo | What it owns |
|---|---|---|
| VMs | `proxmox-vm-bootstrap` (Terraform) | Proxmox VMs, cloud-init |
| Cluster bootstrap | `k3s-cluster-bootstrap` (Ansible) | k3s, kube-vip, MetalLB, Traefik, kured, OS patching, **Argo CD and the root `platform` Application** |
| Platform apps | **this repo** (Argo CD) | Everything below `platform` |
| Charts | e.g. `kube-monitoring-chart` | Helm charts referenced from here |

The root Application is created by the `argocd` role in `k3s-cluster-bootstrap` and points at `apps/platform/` on
`main` here. Argo CD reads only the top level of each directory, so **each file is one Application** and each
subdirectory is the content of the app-of-apps with the same name.

## Adding an app

1. Add `apps/platform/<group>/<app>.yaml` (an `Application`).
2. If `<group>` is new, also add `apps/platform/<group>.yaml` pointing at `apps/platform/<group>`.
3. Merge to `main`. Argo CD syncs automatically (prune + self-heal).

Taking over something already installed with Helm? Use the same `helm.releaseName` and destination namespace, so Argo CD
adopts the existing resources. Then remove Helm's record of the release (the `sh.helm.release.v1.<name>.*` secrets), not
the release itself: `helm uninstall` would delete the resources.

## Access

Argo CD UI: <https://argocd.192.168.86.10.sslip.io> (user `admin`, password in the `argocd-initial-admin-secret` secret).
