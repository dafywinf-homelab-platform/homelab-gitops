# homelab-gitops

Desired state of the Proxmox K3s cluster, deployed by **Argo CD** using the app-of-apps pattern.

```
platform                 root Application (created by Ansible, see below) -> apps/platform/
├── ci                   apps/platform/ci.yaml
│   └── jenkins          Jenkins chart 5.13.3 (LTS 2.580.2): Java builds in Maven/JDK 21 agent pods
│                        (+ ci/jenkins-extras/: jenkins-agents Namespace, where the build pods run)
├── ingress              apps/platform/ingress.yaml
│   └── traefik          Traefik chart 37.0.0 (+ ingress/traefik-extras/: traefik-config ConfigMap), LB 192.168.86.10
├── maintenance          apps/platform/maintenance.yaml
│   └── kured            kured chart 6.1.0: node reboots after OS patching, 03:00-05:00
├── monitoring           apps/platform/monitoring.yaml
│   └── kube-monitoring  kube-monitoring-chart (kube-prometheus-stack)
└── storage              apps/platform/storage.yaml
    └── kube-storage     kube-storage chart (Longhorn 1.12.2 + local-path-mnt-data StorageClass)
```

## How it fits together

| Layer | Repo | What it owns |
|---|---|---|
| VMs | `proxmox-vm-bootstrap` (Terraform) | Proxmox VMs, cloud-init |
| Cluster bootstrap | `k3s-cluster-bootstrap` (Ansible) | k3s, kube-vip, MetalLB, OS patching, system-upgrade-controller, **Argo CD and the root `platform` Application** |
| Platform apps | **this repo** (Argo CD) | Everything below `platform` |
| Charts | e.g. `kube-monitoring-chart` | Helm charts referenced from here |

The root Application is created by the `argocd` role in `k3s-cluster-bootstrap` and points at `apps/platform/` on
`main` here. Argo CD reads only the top level of each directory, so **each file is one Application** and each
subdirectory is the content of the app-of-apps with the same name.
Deeper subdirectories (e.g. `ingress/traefik-extras/`) are not read by the group app; they are extra sources for one
Application.

## Sync order

The group Applications under `platform` carry `argocd.argoproj.io/sync-wave` annotations, so on a fresh cluster (or a
full resync) they come up in dependency order. Argo CD waits for each wave to be **Healthy** before the next one starts:

| Wave | Group | Why |
|---|---|---|
| -3 | storage | StorageClasses and the Longhorn CSI driver before anything requests a volume |
| -2 | ingress | Traefik (CRDs, LoadBalancer `192.168.86.10`) before anything that publishes a UI |
| -1 | maintenance | kured |
| 0 | monitoring | Uses ingress. New groups default to wave 0 as well |
| 1 | ci | Jenkins: a Longhorn volume and an ingress |

Waiting on the *health* of an Application needs Argo CD's Application health check, which Argo CD disabled by default in
1.8. It is enabled in the `argocd` role's Helm values in `k3s-cluster-bootstrap`
(`resource.customizations.health.argoproj.io_Application`). Without it, waves only order *creation*.

## Adding an app

1. Add `apps/platform/<group>/<app>.yaml` (an `Application`).
2. If `<group>` is new, also add `apps/platform/<group>.yaml` pointing at `apps/platform/<group>`.
3. Merge to `main`. Argo CD syncs automatically (prune + self-heal).

Taking over something already installed with Helm? Use the same `helm.releaseName` and destination namespace, so Argo CD
adopts the existing resources. Then remove Helm's record of the release (the `sh.helm.release.v1.<name>.*` secrets), not
the release itself: `helm uninstall` would delete the resources.

## Access

Argo CD UI: <https://argocd.192.168.86.10.sslip.io> (user `admin`, password in the `argocd-initial-admin-secret` secret).

Jenkins: <https://jenkins.192-168-86-10.sslip.io> (user `admin`, password `jenkins_admin_password` in
`k3s-cluster-bootstrap/secrets.yml`, put in the `jenkins/jenkins-admin` Secret by the `platform_secrets` role). Builds run
in agent pods in the `jenkins-agents` namespace (Pod Security `baseline`), never on the controller: use `agent { label 'maven' }` for Maven 3.9 + Temurin JDK 21 (`container('maven')`
for the build steps). Two build pods at most at a time.
