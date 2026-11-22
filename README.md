# homelab-gitops

Desired state of the Proxmox K3s cluster, deployed by **Argo CD** using the app-of-apps pattern.

```
platform                 root Application (created by Ansible, see below) -> apps/platform/
├── ci                   apps/platform/ci.yaml
│   └── jenkins          Jenkins chart 5.13.3 (LTS 2.580.2): Java builds in Maven/JDK 25 agent pods.
│                        Parked (controller.replicas: 0) until the RAM upgrade, to make room for SIT
│                        (+ ci/jenkins-extras/: the jenkins-agents and jenkins-docker Namespaces, where the
│                         build pods run, Jenkins' Role in jenkins-docker, and the jenkins-admin SealedSecret)
├── environments         apps/platform/environments.yaml
│   └── ddd-microservices-lab-sit   SIT of ddd-microservices-lab, from repo ddd-microservices-lab-deploy (app-of-apps;
│                        it and its child Applications sync automatically)
├── ingress              apps/platform/ingress.yaml
│   └── traefik          Traefik chart 37.0.0 (+ ingress/traefik-extras/: traefik-config ConfigMap), LB 192.168.86.10
├── maintenance          apps/platform/maintenance.yaml
│   └── kured            kured chart 6.1.0: node reboots after OS patching, 03:00-05:00
├── monitoring           apps/platform/monitoring.yaml
│   └── kube-monitoring  kube-monitoring-chart (kube-prometheus-stack)
│                        (+ monitoring/kube-monitoring-extras/: grafana-admin SealedSecret)
├── secrets              apps/platform/secrets.yaml
│   └── sealed-secrets   Sealed Secrets chart 2.22.0 (controller 0.41.2): decrypts SealedSecrets from this repo
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
| -4 | secrets | The SealedSecret CRD and controller before any app ships a SealedSecret |
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

Jenkins: <https://jenkins.192-168-86-10.sslip.io> (user `admin`; read the password with
`kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`, change it with
`make seal-jenkins-admin`). Builds run
in agent pods, never on the controller. Two build pods at most at a time.

| Label | Containers | Namespace | Use for |
|---|---|---|---|
| `maven` | `maven` (Maven 3.10 + Temurin JDK 25) | `jenkins-agents` (Pod Security `baseline`) | Builds and tests that don't need Docker |
| `maven-docker` | `maven` + `dind` (Docker 29, privileged) | `jenkins-docker` (Pod Security `privileged`) | Tests that use Testcontainers |

Run build steps in `container('maven')`. In a `maven-docker` pod, Testcontainers finds the pod's own Docker daemon through
`DOCKER_HOST` with no extra setup; every build starts with an empty Docker, so test images are downloaded each time.
Privileged means root on the worker, which is why those pods have a namespace of their own.

## Secrets

Secrets live in this repo as **SealedSecrets**: encrypted with the cluster's public key, so they are safe to commit to
this public repo. Only the sealed-secrets controller in the cluster holds the private key; it turns each SealedSecret
into a normal Secret, which the app reads. Argo CD applies SealedSecrets like any other manifest. Nothing is created
by Ansible or by hand.

```sh
# Seal a new secret (prompts for each value; nothing lands in shell history)
make seal NAMESPACE=my-app NAME=my-app-db KEYS='username password' OUT=apps/platform/<group>/<app>-extras/my-app-db.sealedsecret.yaml
# Change the Jenkins admin login
make seal-jenkins-admin
# Change the Grafana admin login
make seal-grafana-admin
# then commit the file; Argo CD applies it and the controller updates the Secret within seconds
# Jenkins and Grafana read their admin login only at startup: after the change is synced, restart them
#   kubectl -n jenkins rollout restart statefulset jenkins
#   kubectl -n kube-monitoring rollout restart deployment kube-monitoring-grafana
```

| File / place | What | In Git? |
|---|---|---|
| `sealed-secrets/pub-cert.pem` | Public certificate. `kubeseal` encrypts with it (no cluster connection needed) | Yes, it is public by design |
| `*.sealedsecret.yaml` | Encrypted secrets | Yes |
| `~/.homelab/sealed-secrets-key.json` | **Private key** backup (`make backup-sealing-key`), mode 600, FileVault | **Never** |

* Needs `kubeseal` (0.41.2, matching the controller) and `jq`.
* A SealedSecret only decrypts under its own name and namespace (strict scope): copying it elsewhere doesn't work.
* The controller owns the Secrets it creates. Edit the SealedSecret, never the Secret.
* **Rebuilding the cluster:** after Argo CD has installed the controller, run `make restore-sealing-key` (applies the
  backup and restarts the controller). Without the backup, re-seal every secret with the new key (`make fetch-cert`,
  then `make seal…`).

Design, flows and the reasoning: homelab-architecture `docs/09-secrets.md` and ADR-010.
