# gitops-manifests

This repo describes **what should run** on our Kubernetes (EKS) clusters.
Argo CD reads it and makes the cluster match it.

> **New to this?** Read the sections in order. Each one builds on the one before.
> You don't need to know Argo CD or Kubernetes already. Short definitions are in the
> [Glossary](#9-glossary) at the end.

---

## Contents

1. [The idea in one minute (GitOps)](#1-the-idea-in-one-minute-gitops)
2. [How a change reaches the cluster](#2-how-a-change-reaches-the-cluster)
3. [Folder map](#3-folder-map)
4. [The Kubernetes files, one by one](#4-the-kubernetes-files-one-by-one)
5. [Rolling update: how we deploy with zero downtime](#5-rolling-update-how-we-deploy-with-zero-downtime)
6. [Base and overlays (dev vs prod)](#6-base-and-overlays-dev-vs-prod)
7. [Everyday tasks (step by step)](#7-everyday-tasks-step-by-step)
8. [Checking and troubleshooting](#8-checking-and-troubleshooting)
9. [Glossary](#9-glossary)
10. [One-time setup](#10-one-time-setup)

---

## 1. The idea in one minute (GitOps)

**Old way:** someone runs `kubectl apply` from their laptop. Nobody knows exactly what
is running, and changes are hard to review or undo.

**GitOps way:**

- **Git is the single source of truth.** The YAML in this repo describes exactly what should run.
- **Argo CD** runs inside the cluster and watches this repo. When Git changes, Argo CD
  applies the change. If someone changes the cluster by hand, Argo CD puts it back (*self-heal*).
- **Every change is a commit**, so it is reviewed in a pull request, has a history,
  and can be undone with `git revert`.

> **Golden rule:** don't change the cluster with `kubectl apply/edit`. Change the YAML here,
> commit, push. Argo CD does the rest.

---

## 2. How a change reaches the cluster

```
 Developer                 CI (GitHub Actions)          This repo (Git)           Argo CD (in cluster)        EKS
 ─────────                 ───────────────────          ───────────────           ────────────────────        ───
 push code   ──────────▶   test + build image
                           push image to ECR
                           (tag e.g. 1.2.0)
                           commit new tag      ──────▶  overlays/dev updated
                                                                       ──────▶   notices the new commit
                                                                                 applies the YAML     ──────▶  rolling update
                                                                                                               new pods live
```

Who installs what:

| Thing | Installed by |
|---|---|
| EKS cluster, Argo CD, Prometheus/Grafana, the *root app* | Terraform (`infra-terraform` repo) |
| Everything in this repo (our apps, alert rules) | Argo CD, from Git |

### App of Apps

Argo CD manages itself with a pattern called **App of Apps**:

```
root-app  (created by Terraform, points at argocd/apps/)
   ├── platform-demo   → apps/platform-demo/overlays/dev   (our frontend + backend)
   └── monitoring      → monitoring/alerts                 (Prometheus alert rules)
```

To add a new app to the cluster, add a new Application file in `argocd/apps/` and list it
in `argocd/apps/kustomization.yaml`. The root app picks it up automatically.

---

## 3. Folder map

```
ArgoCD/
├── argocd/                          ← Argo CD's own config ("what to deploy, from where")
│   ├── root-app.yaml                  root App of Apps (Terraform creates it; manual fallback only)
│   └── apps/
│       ├── kustomization.yaml         list of child apps that are switched ON
│       ├── platform-demo.yaml         our app, built with Kustomize   (ON)
│       ├── platform-demo-helm.yaml    same app, built with Helm       (OFF, alternative)
│       └── monitoring.yaml            alert rules
│
├── apps/platform-demo/              ← our app's Kubernetes YAML (Kustomize)
│   ├── base/                          shared by every environment
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── backend/                   Node.js API on port 3000
│   │   │   ├── kustomization.yaml       file list + ConfigMap (backend-config)
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── hpa.yaml
│   │   │   ├── pdb.yaml
│   │   │   ├── secret.yaml
│   │   │   └── servicemonitor.yaml
│   │   └── frontend/                  React + nginx on port 8080 (public)
│   │       ├── kustomization.yaml       file list + ConfigMap (frontend-config)
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── ingress.yaml
│   │       ├── hpa.yaml
│   │       └── pdb.yaml
│   └── overlays/                      what is different per environment
│       ├── dev/kustomization.yaml
│       └── prod/kustomization.yaml
│
├── charts/platform-demo/            ← the same app as a Helm chart (alternative to apps/)
│   ├── Chart.yaml
│   ├── values.yaml, values-dev.yaml, values-prod.yaml
│   └── templates/                     deployment, service, ingress, hpa, configmap, secret, pdb, servicemonitor
│
└── monitoring/
    ├── alerts/                        Prometheus alert rules (synced by Argo CD)
    └── kube-prometheus-stack/         extra values for the Terraform-installed monitoring (NOT synced by Argo CD)
```

> **Kustomize or Helm?** Both build the same app. Only **one** may be switched on, because
> they manage the same objects. Today `platform-demo.yaml` (Kustomize) is on.
> To switch, edit `argocd/apps/kustomization.yaml`.

---

## 4. The Kubernetes files, one by one

How user traffic flows through the objects:

```
 Internet
    │
    ▼
 Ingress (frontend)        → creates an AWS Application Load Balancer
    │
    ▼
 Service: frontend :80     → stable address in front of the frontend pods
    │
    ▼
 Pods: frontend (nginx)    ── /api/ requests ──▶  Service: backend :3000  ──▶  Pods: backend (Node.js)
    ▲                                                                            ▲
 HPA adds/removes pods                                                     HPA adds/removes pods
```

| File | Kind | What it does, in plain words |
|---|---|---|
| `namespace.yaml` | Namespace | A "folder" in the cluster called `platform-demo`. Also enforces strict pod security (no root). |
| `deployment.yaml` | Deployment | "Run this container image, keep it healthy, and replace pods one at a time when the image changes." Holds the image, ports, health checks, CPU/memory, and the rolling update settings. |
| `service.yaml` | Service | A fixed internal name and IP for a group of pods. Pods come and go; `http://backend:3000` always works. |
| `ingress.yaml` | Ingress | Opens the frontend to the internet. The AWS Load Balancer Controller turns it into a real AWS load balancer. Only the frontend has one; the backend stays private. |
| `hpa.yaml` | HorizontalPodAutoscaler | Adds pods when CPU is above 70%, removes them when load drops. Scales up fast, scales down slowly (waits 5 min). |
| `kustomization.yaml` → `configMapGenerator` | ConfigMap | Normal settings (e.g. `APP_ENV=dev`, `LOG_LEVEL`), given to the container as environment variables. |
| `secret.yaml` | Secret | Passwords and API keys, given to the container as environment variables. **Never put a real secret in Git** (see [7.4](#74-change-a-secret)). |
| `pdb.yaml` | PodDisruptionBudget | During node maintenance, never take down more than 1 pod of this app at a time. |
| `servicemonitor.yaml` | ServiceMonitor | Tells Prometheus to collect metrics from the backend's `/metrics` page. |

### What's inside a Deployment (backend example)

```yaml
containers:
  - name: backend
    image: backend                 # real image + tag is set in overlays/<env>
    ports:
      - containerPort: 3000
    envFrom:
      - configMapRef: { name: backend-config }   # settings
      - secretRef:    { name: backend-secret }   # secrets
    readinessProbe:  /readyz       # "Am I ready for traffic?"  No → no traffic sent
    livenessProbe:   /healthz      # "Am I still alive?"         No → container restarted
    resources:
      requests: { cpu: 50m, memory: 64Mi }        # guaranteed minimum (HPA % is based on this)
      limits:   { memory: 256Mi }                 # hard maximum
```

> **Why is there no `replicas:` in the Deployment?** The HPA decides how many pods run.
> If we also wrote `replicas: 2`, Argo CD would keep resetting the HPA's choice back to 2.
> To change the pod count, change `minReplicas`/`maxReplicas` in the overlay.

---

## 5. Rolling update: how we deploy with zero downtime

When the image tag changes, Kubernetes replaces old pods with new ones **gradually**:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1         # at most 1 EXTRA pod during the update
    maxUnavailable: 0   # never fewer working pods than we asked for
minReadySeconds: 5            # a new pod must stay healthy 5s before it counts
progressDeadlineSeconds: 300  # stuck for 5 min → rollout marked failed
```

Example with 3 pods (v1 → v2):

```
Start          v1 v1 v1
Step 1         v1 v1 v1 v2      ← 1 new pod starts (maxSurge: 1), waits until /readyz is OK
Step 2         v1 v1 v2         ← only then 1 old pod is removed
Step 3         v1 v1 v2 v2
Step 4         v1 v2 v2
 ...
Done           v2 v2 v2         ← users never saw an outage
```

Three more things make it safe:

- **readinessProbe:** a new pod gets no traffic until it says it's ready. If v2 is broken, it never
  becomes ready, the rollout stops, and the v1 pods keep serving.
- **preStop sleep 5s:** before a pod shuts down, it waits 5 seconds so the load balancer
  stops sending it requests first.
- **Config changes also roll:** Kustomize adds a hash to the ConfigMap name
  (`backend-config-h588hdc8kc`). New values → new name → pods restart with the new settings.

---

## 6. Base and overlays (dev vs prod)

We don't copy the whole YAML for each environment. We use **Kustomize**:

- **base/** = everything that's the same everywhere.
- **overlays/dev** and **overlays/prod** = only the differences, applied on top of base.

```
 base/  ──┬── + overlays/dev   ──▶  what runs in dev
          └── + overlays/prod  ──▶  what runs in prod
```

| Setting | dev | prod |
|---|---|---|
| Image registry | `.../dev/backend`, `.../dev/frontend` | `.../prod/backend`, `.../prod/frontend` |
| Pods (HPA min–max) | backend 1–3, frontend 1–3 | backend 3–10, frontend 3–6 |
| `APP_ENV` / `LOG_LEVEL` | `dev` / `debug` | `prod` / `info` |
| Backend CPU/memory | 50m / 256Mi limit | 200m / 512Mi limit |
| Secret | placeholder from `base/backend/secret.yaml` | real one, created outside Git |
| HTTPS + domain | no (plain HTTP) | yes, `demo.example.com` with an ACM certificate |

See the final YAML any time (nothing is sent to the cluster):

```sh
kubectl kustomize apps/platform-demo/overlays/dev
kubectl kustomize apps/platform-demo/overlays/prod
```

---

## 7. Everyday tasks (step by step)

Every task ends the same way: **commit → push → Argo CD syncs** (within about 3 minutes, or press
*Refresh* in the Argo CD UI).

### 7.1 Deploy a new version

Usually CI does this for you. By hand:

```sh
cd apps/platform-demo/overlays/dev
kustomize edit set image backend=111122223333.dkr.ecr.us-east-1.amazonaws.com/dev/backend:1.2.0
# or open kustomization.yaml and change newTag: "1.2.0"
git commit -am "platform-demo: backend 1.2.0"
git push
```

Image tags are **immutable** (never reuse `1.2.0` for different code). Don't use `latest`.

**Promote to prod:** put the same tag (the one tested in dev) in `overlays/prod/kustomization.yaml`.

### 7.2 Roll back

```sh
git log --oneline            # find the bad commit
git revert <commit-id>
git push
```

Argo CD deploys the previous version again with a normal rolling update.
Don't roll back from the Argo CD UI: self-heal would bring the bad version back from Git.

### 7.3 Change a setting (ConfigMap)

- **All environments:** edit `configMapGenerator` in `base/backend/kustomization.yaml`
  (or `base/frontend/...`).
- **One environment:** edit `configMapGenerator` in `overlays/<env>/kustomization.yaml`.

```yaml
configMapGenerator:
  - name: backend-config
    behavior: merge
    literals:
      - APP_ENV=dev
      - LOG_LEVEL=debug
      - FEATURE_X=true     # ← new setting
```

The pods restart automatically with the new value.

### 7.4 Change a secret

- **dev:** the placeholder lives in `base/backend/secret.yaml` and is not a real secret.
- **prod:** the placeholder is deleted by the prod overlay. The real `backend-secret` must be
  created **outside Git**, ideally with External Secrets Operator + AWS Secrets Manager, or by hand:

  ```sh
  kubectl -n platform-demo create secret generic backend-secret --from-literal=API_KEY=...
  ```

Secret changes **don't** restart pods automatically. After changing one:

```sh
kubectl -n platform-demo rollout restart deployment/backend
```

> Never commit real passwords, tokens or keys. Anyone with access to the repo can read them,
> and they stay in Git history forever.

### 7.5 Change the number of pods

Edit the HPA patch in `overlays/<env>/kustomization.yaml` (`minReplicas` / `maxReplicas`).
Don't add `replicas:` to the Deployment ([why](#4-the-kubernetes-files-one-by-one)).

### 7.6 Add a new app

1. Create `apps/<new-app>/base` and `overlays/` (copy `platform-demo` as a starting point).
2. Create `argocd/apps/<new-app>.yaml` (copy `platform-demo.yaml`, change `name`, `path`, `namespace`).
3. Add the file to `argocd/apps/kustomization.yaml`.
4. Commit and push. The root app creates the new Argo CD Application.

---

## 8. Checking and troubleshooting

### Open the Argo CD UI

```sh
kubectl -n argocd port-forward svc/argocd-server 8081:443
# open https://localhost:8081   user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

What the colors mean:

| Status | Meaning |
|---|---|
| **Synced** | The cluster matches Git. |
| **OutOfSync** | Git has changes not applied yet (or someone changed the cluster by hand). |
| **Healthy** | All pods are running and ready. |
| **Progressing** | A rollout is in progress. |
| **Degraded** | Something is broken, e.g. pods crashing or a rollout stuck over 5 min. |

### Useful commands

```sh
kubectl -n platform-demo get pods                          # are the pods running?
kubectl -n platform-demo get deploy,svc,ingress,hpa        # overview of everything
kubectl -n platform-demo rollout status deployment/backend # watch a rollout
kubectl -n platform-demo describe pod <pod-name>           # why isn't a pod starting? (see Events)
kubectl -n platform-demo logs deployment/backend           # app logs
kubectl -n platform-demo get ingress frontend              # ADDRESS = public load balancer URL
kubectl -n platform-demo port-forward svc/frontend 8080:80 # open http://localhost:8080
```

### Common problems

| You see | Likely cause | What to do |
|---|---|---|
| Pod `ImagePullBackOff` | Wrong image name/tag, or the tag isn't in ECR | Check `newName`/`newTag` in the overlay; check ECR. |
| Pod `CrashLoopBackOff` | The app crashes at startup | `kubectl logs <pod> --previous` |
| Pod `Running` but `0/1` ready | `/readyz` fails | Check app logs and the readinessProbe path/port. |
| App stays `OutOfSync` | Sync error | Open the app in the Argo CD UI and read the error message. |
| `ServiceMonitor` sync error on a new cluster | Monitoring is still installing | Wait; Argo CD retries automatically. |
| HPA shows `<unknown>/70%` | metrics-server is missing | Install metrics-server ([setup](#10-one-time-setup)). |
| Ingress has no ADDRESS | AWS Load Balancer Controller is missing | Install it ([setup](#10-one-time-setup)). |
| My `kubectl edit` change disappeared | Self-heal reverted it | Make the change in Git instead. |

**Before pushing, always check that the YAML builds:**

```sh
kubectl kustomize apps/platform-demo/overlays/dev  > /dev/null && echo OK
kubectl kustomize argocd/apps                      > /dev/null && echo OK
```

---

## 9. Glossary

| Word | Meaning |
|---|---|
| **GitOps** | Running infrastructure from Git: the repo is the truth, a tool makes the cluster match it. |
| **Argo CD** | The tool that watches this repo and applies it to the cluster. |
| **Application** | An Argo CD object: "deploy this folder of this repo into this namespace". |
| **Sync** | Argo CD applying Git to the cluster. |
| **Self-heal** | Argo CD undoing manual changes in the cluster. |
| **Prune** | Argo CD deleting objects that were removed from Git. |
| **Pod** | One running copy of the app (one or more containers). |
| **Namespace** | A named group of objects in the cluster, like a folder. |
| **Probe** | A health check Kubernetes calls regularly (readiness = ready for traffic, liveness = still alive). |
| **Kustomize** | Builds the final YAML from `base` + an environment `overlay`. Built into `kubectl`. |
| **Helm** | Another way to build YAML, using templates + values files (`charts/`). |
| **ECR** | AWS's container image registry, where CI pushes our images. |
| **ALB** | AWS Application Load Balancer, created from our Ingress. |
| **EKS** | AWS's managed Kubernetes. |

---

## 10. One-time setup

Done once per cluster. You won't need this day to day.

**1. Replace placeholders.** Search the repo for `CHANGE ME`:
- Git repo URL in `argocd/*.yaml` and `argocd/apps/*.yaml`
- AWS account ID in `overlays/dev` and `overlays/prod` (and `charts/platform-demo/values*.yaml`)
- ACM certificate ARN and domain name in `overlays/prod`

**2. Point Terraform at this repo.** In `infra-terraform/envs/<env>/terraform.tfvars`:

```hcl
gitops_repo_url  = "https://github.com/my-org/gitops-manifests.git"
gitops_repo_path = "argocd/apps"
```

**3. Install cluster add-ons.** Terraform doesn't install these yet:

- **metrics-server**: gives CPU usage to the HPAs (`kubectl top pods` should work).
- **AWS Load Balancer Controller** (with an IRSA role): turns the Ingress into an ALB.

**4. Create the prod secret** `backend-secret` in the `platform-demo` namespace ([7.4](#74-change-a-secret)).
