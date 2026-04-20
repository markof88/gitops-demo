# GitOps Demo

---

## What Is This Demo

This demo shows a GitOps workflow built on ArgoCD, Kustomize, GitHub Actions, and SealedSecrets. The goal is to prove that the entire lifecycle of an application, deployment, secrets, database schema, permissions, can be managed declaratively from Git, with no manual steps on the cluster after the initial bootstrap.

The demo application is a simple NGINX web app backed by a PostgreSQL database. It is intentionally minimal so the focus stays on the infrastructure patterns, not the application code.

---

## Repository Structure, Top Level

```
gitops-demo/
  app/                  → application source code (what gets built into a Docker image)
  apps/                 → Kubernetes manifests for all applications
  clusters/             → ArgoCD configuration per cluster/environment
  bootstrap/            → one-time bootstrap: the root ArgoCD Application
  .github/workflows/    → CI pipeline (GitHub Actions)
```

These four directories represent four completely separate concerns. Understanding what lives where, and why, is the key to understanding the whole system.

---

## `app/` The Application Source Code

```
app/
  Dockerfile      → builds an NGINX image, copies index.html into it
  index.html      → static HTML page served by NGINX
```

`Dockerfile`:
```dockerfile
FROM nginx:1.25-alpine
COPY index.html /usr/share/nginx/html/index.html
```

That is the entire application. One HTML file served by NGINX. It is intentionally trivial, the interesting part is everything around it, not the app itself.

**What triggers a build:** GitHub Actions watches for any push to `main` that touches the `app/**` path. If you change `index.html` and push, a new Docker image is built. If you change something in `apps/` or `clusters/`, the CI pipeline does not run at all. there is nothing to build.

---

## `.github/workflows/`, The CI Pipeline

File: `.github/workflows/build.yml`

**Trigger:** push to `main` where files under `app/` changed.

**What it does, step by step:**

1. **Builds a multi-architecture image** `linux/amd64` and `linux/arm64`. Both architectures are needed because development happens on Apple Silicon (arm64) but the cluster runs on amd64. Without multi-arch, the image would not run on GitHub Actions or in production.

2. **Pushes to GitHub Container Registry** the image is tagged with two tags: `latest` and the full Git commit SHA (e.g. `ghcr.io/markof88/gitops-demo/demo-app:2fad36b...`). The SHA tag is what gets used for deployment. it is immutable and traceable back to the exact commit.

3. **Updates the image tag in Git** this is the critical step. After pushing the image, CI runs:
   ```bash
   kustomize edit set image demo-app=ghcr.io/markof88/gitops-demo/demo-app:<SHA>
   ```
   This updates `apps/demo-app/overlays/dev/kustomization.yaml` with the new tag and commits it back to `main` with the message `deploy: update demo-app to <SHA>`.

4. **CI never touches the cluster** it only writes to Git. ArgoCD reads from Git. That is the entire handoff.

---

## `apps/` Kubernetes Manifests (Kustomize)

**What is Kustomize:** Kustomize is a Kubernetes-native configuration management tool built into `kubectl`. Instead of using templates with variables (like Helm), it works by defining a base set of YAML resources and applying environment-specific patches on top. There are no `{{ variables }}` or conditionals. just plain Kubernetes YAML, layered.

```
apps/demo-app/
  base/           → shared resources, identical across all environments
  overlays/
    dev/          → dev-specific overrides layered on top of base
    stage/        → stage-specific overrides
    prod/         → prod-specific overrides
```

### `apps/demo-app/base/` Shared Resources

This is the single source of truth for how the application is defined. Every environment starts from here.

**`kustomization.yaml`** the index file. Lists all resources Kustomize should include:
```yaml
resources:
- deployment.yaml
- service.yaml
- pdb.yaml
- postgres.yaml
- postgres-netpol.yaml
- db-bootstrap-job.yaml
- migration-job.yaml
```

**`deployment.yaml`** the main app deployment. Defines the NGINX container, the two environment variables injected from secrets (`SECRET_MESSAGE`, `TEAM_MESSAGE`), resource requests/limits, and readiness/liveness probes. Annotated with `sync-wave: "4"` . It deploys last, after the database is ready.

**`service.yaml`** exposes the app as a `LoadBalancer` service on port 80. This is how you access the app from outside the cluster.

**`pdb.yaml`** PodDisruptionBudget. Tells Kubernetes: during voluntary disruptions (node drain, rolling update), at most 1 pod can be unavailable at a time. Prevents the app from going fully down during deployments when running 2 replicas.

**`postgres.yaml`** PostgreSQL deployment + service. Runs `postgres:15-alpine`, reads the superuser password from `postgres-secret`, exposes port 5432 internally. Uses `emptyDir` for storage (data is ephemeral, this is a demo, not a production setup). Annotated with `sync-wave: "1"`. It must be up and healthy before anything else runs.

**`postgres-netpol.yaml`** NetworkPolicy. Restricts who can talk to the Postgres pod on port 5432. Only two things are allowed ingress:
- The `demo-app` pods (label `app: demo-app`)
- The bootstrap and migration jobs (by `job-name` label)

Nobody else can reach Postgres, even within the cluster.

**`db-bootstrap-job.yaml`** a Kubernetes Job that runs once per sync (wave 2). It connects to Postgres as the superuser and:
1. Creates the application-scoped database user (`demo_app`) if it does not exist, or updates the password if it does
2. Grants the user connect, schema usage, and create permissions on the `demo` database
3. Transfers ownership of all existing tables to that user

This means the application never connects to Postgres with superuser credentials. It uses a dedicated user with only the permissions it needs.

**`migration-job.yaml`** a Kubernetes Job that runs once per sync (wave 3). It connects as the app-scoped user (`demo_app`) and runs SQL migrations idempotently:
- 001: create `messages` table
- 002: add `team_message` column
- 003: seed initial row (only if table is empty)
- 004: add `deployment_source` column
- 005: add `demo_version` column

All migrations use `IF NOT EXISTS` or `IF NOT EXISTS` guards, safe to run repeatedly. If a migration was already applied, it is skipped with a notice.

Both jobs are annotated as ArgoCD `Sync` hooks with `BeforeHookCreation` delete policy. ArgoCD deletes the old job before creating a new one on each sync, so they always run fresh.

### `apps/demo-app/overlays/dev/` Dev Environment Overrides

ArgoCD for dev points at this path: `apps/demo-app/overlays/dev`. Kustomize merges base + overlay to produce the final manifests applied to the cluster.

**`kustomization.yaml`** the overlay index. It pulls in the base, adds dev-specific secrets, applies patches, and sets the image tag:
```yaml
resources:
- ../../base          # pull in everything from base/
- sealed-secret.yaml
- postgres-secret.yaml
- app-db-sealed-secret.yaml

patches:
- path: replica-patch.yaml

images:
- name: demo-app
  newName: ghcr.io/markof88/gitops-demo/demo-app
  newTag: 72fdffbc...   # ← CI updates this line on every deploy
```

**`replica-patch.yaml`** patches the base Deployment to set `replicas: 2` for dev. In prod this would be `3`.

**`postgres-secret.yaml`** plaintext Kubernetes Secret containing the Postgres superuser password (`demo-password`). Plaintext is acceptable in dev only — in stage and prod this is replaced with a SealedSecret.

**`sealed-secret.yaml`** encrypted SealedSecret for `demo-secret` (the app messages). Encrypted with the cluster's public key via `kubeseal`. Contains `message` and `team-message` fields sourced from 1Password. Safe to commit, only this specific cluster can decrypt it.

**`app-db-sealed-secret.yaml`** encrypted SealedSecret for `app-db-secret` (the DB credentials). Contains `username: demo_app` and `password` sourced from 1Password. Used by both the bootstrap job and the migration job to connect to Postgres.

---

## `clusters/` ArgoCD Configuration

```
clusters/dev/
  project.yaml      → AppProject: the permissions boundary
  demo-app.yaml     → Application: what to watch and where to deploy
```

**`project.yaml`** — defines the `caralegal-dev` AppProject. This is ArgoCD's security boundary. It explicitly lists:
- Which Git repos ArgoCD is allowed to pull from
- Which cluster namespaces it can deploy into (`demo`)
- Which Kubernetes resource types it is allowed to create (`Deployment`, `Service`, `Job`, `SealedSecret`, `NetworkPolicy`, etc.)

If a resource type is not listed here, ArgoCD will refuse to apply it, even if it is in Git. This is how you prevent ArgoCD from being used to deploy arbitrary cluster-wide resources.

**`demo-app.yaml`** defines the `demo-app` ArgoCD Application. It tells ArgoCD:
- Watch this repo: `github.com/markof88/gitops-demo`
- Watch this path: `apps/demo-app/overlays/dev`
- Deploy to this namespace: `demo`
- Use this project: `caralegal-dev`
- Sync policy: automated, with pruning (delete resources removed from Git) and self-heal (revert manual cluster changes)
- `CreateNamespace=true`: create the `demo` namespace if it does not exist

---

## `bootstrap/` App of Apps

```
bootstrap/
  root-app.yaml   → the root ArgoCD Application
```

**The problem this solves:** `project.yaml` and `demo-app.yaml` in `clusters/dev/` are Kubernetes resources. they need to be applied to the cluster somehow. Without this, any change to the AppProject or the Application definition requires a manual `kubectl apply`. That breaks the GitOps principle.

**The solution:** `root-app.yaml` is an ArgoCD Application that watches `clusters/dev/` in Git and manages `project.yaml` and `demo-app.yaml`. This makes ArgoCD manage its own configuration from Git.

```yaml
source:
  path: clusters/dev        # watches this folder in Git
destination:
  namespace: argocd         # applies resources into the argocd namespace
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

**The bootstrapping step:** `root-app.yaml` itself is the one thing that cannot manage itself. it must be applied manually once:
```bash
kubectl apply -f bootstrap/root-app.yaml
```

After that, everything else flows from Git. This is the only `kubectl apply` you ever need to run.

**The result in ArgoCD UI:**
- `root-app` → manages → `caralegal-dev` AppProject + `demo-app` Application
- `demo-app` → manages → all application resources in the `demo` namespace

---

## How It All Fits Together

```
1. Developer pushes a change to app/index.html
       ↓
2. GitHub Actions detects the push (paths: app/**)
   - builds multi-arch Docker image
   - pushes to ghcr.io with the commit SHA as tag
   - updates apps/demo-app/overlays/dev/kustomization.yaml with new tag
   - commits "deploy: update demo-app to <SHA>" back to main
       ↓
3. ArgoCD detects the new commit in the repo (polls every 3 min or via webhook)
   - compares desired state (Git) vs actual state (cluster)
   - detects the image tag changed
   - runs the sync wave sequence:
       wave 0: secrets, services
       wave 1: postgres (waits until healthy)
       wave 2: db-bootstrap job (runs, waits until complete)
       wave 3: migration job (runs, waits until complete)
       wave 4: demo-app deployment (rolls out with new image)
       ↓
4. New pods are running the new image. Rollout complete.
   CI never touched the cluster. The cluster state matches Git exactly.
```

---

## Architecture Overview

**What is built:**

```
Push to main
  → GitHub Actions: build multi-arch image (amd64+arm64) → push to ghcr.io
  → CI commits new image tag back to Git
  → ArgoCD detects the commit → rolls out new pods automatically
```

**Repo structure:**
```
app/                          → NGINX demo app source (Dockerfile + index.html)
apps/demo-app/base/           → Kustomize base: deployment, service, postgres, jobs, netpol, pdb
apps/demo-app/overlays/dev/   → dev-specific: replicas, resources, sealed secrets, image tag
clusters/dev/
  project.yaml                → AppProject (what ArgoCD is allowed to manage)
  demo-app.yaml               → ArgoCD Application (what to sync and where)
bootstrap/
  root-app.yaml               → The App of Apps, bootstraps everything above
```

**Sync wave order (every sync runs in this sequence):**
| Wave | Resource | Purpose |
|------|----------|---------|
| 0 | secrets, services | prerequisites |
| 1 | postgres deployment | wait for DB to be ready |
| 2 | db-bootstrap job | create app-scoped DB user, grant permissions |
| 3 | migration job | run schema migrations, seed data |
| 4 | demo-app deployment | application |

**Secrets strategy:**
- Secrets live in 1Password
- `op read` fetches them live → piped into `kubeseal` → encrypted SealedSecret committed to Git
- Plaintext never touches disk

---

## 0. Prerequisites

```bash
# Verify tools
kubectl version --client
argocd version --client
kubeseal --version
op --version
psql --version
gh --version

# Verify cluster is up
kubectl get nodes

# Start ArgoCD UI port-forward (keep this terminal open)
kubectl port-forward svc/argocd-server -n argocd 8080:80
# UI: http://localhost:8080

# Login to ArgoCD CLI
argocd login localhost:8080 --insecure --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

---

## 1. Start from scratch, one command deploys the entire stack

**What this shows:** The whole infrastructure is in Git. One `kubectl apply` bootstraps
everything, ArgoCD creates the AppProject, the Application, and syncs the full stack
with the correct wave order.

```bash
# Clean slate, delete everything
kubectl delete application root-app -n argocd --ignore-not-found
kubectl delete application demo-app -n argocd --ignore-not-found
kubectl delete namespace demo --ignore-not-found

# Confirm nothing is running
kubectl get applications -n argocd
kubectl get all -n demo 2>&1

# The entire desired state is already in Git.
# One command to bootstrap:
kubectl apply -f bootstrap/root-app.yaml

# ArgoCD now:
#   1. Syncs clusters/dev/ → creates AppProject (caralegal-dev) and demo-app Application
#   2. demo-app syncs with waves: secrets → postgres → db-bootstrap → migration → demo-app

# Watch it happen live
kubectl get pods -n demo -w
```

```bash
# Check sync wave progress in ArgoCD UI or via CLI
argocd app get demo-app --refresh

# Watch jobs complete in order (bootstrap wave 2, migration wave 3)
kubectl get jobs -n demo -w
```

```bash
# Confirm everything is up
kubectl get all -n demo
argocd app get demo-app
```

```bash
# Get the app URL and open it
kubectl get svc demo-app -n demo
# Open: http://<EXTERNAL-IP>
```

---

## 2. Seal a secret from 1Password. no plaintext ever touches disk

**What this shows:** Secrets are fetched live from 1Password and piped straight into kubeseal.
The only file written to disk is the encrypted SealedSecret, safe to commit to a public repo.

```bash
# Sign in to 1Password
eval $(op signin)

# Fetch the cluster's Sealed Secrets public cert (safe to share — it's a public key)
kubeseal --controller-name sealed-secrets --controller-namespace kube-system --fetch-cert > ./dev-pub.pem

# Seal demo-secret (app message + team message)
kubectl create secret generic demo-secret \
  -n demo \
  --from-literal=message="$(op read 'op://gitops-demo/demo-secret/message')" \
  --from-literal=team-message="$(op read 'op://gitops-demo/demo-secret/team-message')" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets --controller-namespace kube-system --cert ./dev-pub.pem --format yaml \
  > apps/demo-app/overlays/dev/sealed-secret.yaml

# Seal app-db-secret (app-scoped DB credentials)
kubectl create secret generic app-db-secret \
  -n demo \
  --from-literal=username="demo_app" \
  --from-literal=password="$(op read 'op://gitops-demo/demo-app-db/password')" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets --controller-namespace kube-system --cert ./dev-pub.pem --format yaml \
  > apps/demo-app/overlays/dev/app-db-sealed-secret.yaml

# Show the file — only encrypted gibberish, no plaintext
cat apps/demo-app/overlays/dev/sealed-secret.yaml

# Commit and push — ArgoCD applies the new SealedSecrets automatically
git add apps/demo-app/overlays/dev/sealed-secret.yaml \
        apps/demo-app/overlays/dev/app-db-sealed-secret.yaml
git commit -m "chore: rotate dev sealed secrets"
git push origin main

# Verify the secret is decrypted and live in the cluster
kubectl get secret demo-secret -n demo -o jsonpath='{.data.message}' | base64 -d
```

---

## 3. Inspect the database, what the sync waves actually did

**What this shows:** The db-bootstrap job (wave 2) created an app-scoped DB user.
The migration job (wave 3) created the schema and seeded data. Both ran automatically on sync.

```bash
# Port-forward postgres (run in a separate terminal)
kubectl port-forward svc/postgres 5432:5432 -n demo &

# Get superuser password from cluster
export PGPASSWORD=$(kubectl get secret postgres-secret -n demo -o jsonpath='{.data.password}' | base64 -d)

# Connect as superuser
psql -h localhost -U demo -d demo

# Inside psql:
\dt                       -- tables created by migration job (wave 3)
\du                       -- roles: 'demo' (superuser) + app-scoped user (created by wave 2)
SELECT * FROM messages;   -- seeded row: "Hello from GitOps!" / "Deployed by ArgoCD"
\q
```

```bash
# Connect as the app-scoped user (created by db-bootstrap, wave 2)
export APP_USER=$(kubectl get secret app-db-secret -n demo -o jsonpath='{.data.username}' | base64 -d)
export APP_PASS=$(kubectl get secret app-db-secret -n demo -o jsonpath='{.data.password}' | base64 -d)

PGPASSWORD=$APP_PASS psql -h localhost -U $APP_USER -d demo

SELECT * FROM messages;   -- app user owns its tables
\q
```

---

## 4. Change DB permissions, AppProject update flows through Git

**What this shows:** Previously AppProject changes required manual kubectl apply.
Now root-app manages it. change project.yaml in Git, push, ArgoCD applies it automatically.

```bash
# Example: add a new allowed resource kind to the AppProject
# Edit clusters/dev/project.yaml. add a new entry under namespaceResourceWhitelist:
#
#     - group: autoscaling
#       kind: HorizontalPodAutoscaler

# After editing:
git add clusters/dev/project.yaml
git commit -m "feat: allow HPA in caralegal-dev project"
git push origin main

# Watch root-app pick up the change and apply it
argocd app get root-app --refresh

# Verify the AppProject was updated on the cluster
kubectl get appproject caralegal-dev -n argocd -o jsonpath='{.spec.namespaceResourceWhitelist}' \
  | python3 -m json.tool
```

---

## 5. Add a schema migration. sync waves enforce correct order

**What this shows:** Schema changes are code. Add a migration, push. ArgoCD's sync waves
guarantee: migration runs and completes before the app deployment starts.
If the migration fails, the app does not deploy.

```bash
# Add a new migration step to the migration job
# Edit apps/demo-app/base/migration-job.yaml
# Find the line: echo "All migrations completed successfully."
# Insert before it:
#
#          echo "006: add presented_at column..."
#          psql -c "ALTER TABLE messages ADD COLUMN IF NOT EXISTS presented_at TIMESTAMP DEFAULT NOW();"

git add apps/demo-app/base/migration-job.yaml
git commit -m "feat: add presented_at column (migration 006)"
git push origin main

# Watch the waves execute in order
kubectl get jobs -n demo -w

# Tail migration job logs
kubectl logs -l job-name=demo-app-migration -n demo --follow

# Verify the new column
psql -h localhost -U demo -d demo -c "\d messages"
psql -h localhost -U demo -d demo -c "SELECT * FROM messages;"
```

---

## 6. Code change → CI builds image → ArgoCD rolls out

**What this shows:** The full GitOps loop. Push app code, CI builds and pushes the image,
commits the new tag back to Git, ArgoCD detects the tag change and rolls out new pods.

```bash
# Change the app (bump to next version, check current first)
grep "GitOps Demo" app/index.html

sed -i '' 's/GitOps Demo — v[0-9]*/GitOps Demo — v2/' app/index.html
grep "v2" app/index.html

git add app/index.html
git commit -m "feat: bump demo to v2"
git push origin main

# Watch GitHub Actions build and push the image
gh run watch

# CI commits a new image tag to apps/demo-app/overlays/dev/kustomization.yaml
# ArgoCD detects the commit and rolls out new pods
kubectl rollout status deployment/demo-app -n demo

# Confirm the new version is live
curl http://$(kubectl get svc demo-app -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

---

## 7. Rollback -> revert to previous version via Git

**What this shows:** Rollback is a git revert. The previous state is in Git history.
Revert the commit, push. ArgoCD rolls back automatically. No special rollback commands.

```bash
# Show current image tag deployed
kubectl get deployment demo-app -n demo -o jsonpath='{.spec.template.spec.containers[0].image}'

# Revert the last CI image tag commit
git log --oneline -5
git revert HEAD --no-edit
git push origin main

# ArgoCD detects the revert and rolls back
kubectl rollout status deployment/demo-app -n demo

# Confirm old version is live
curl http://$(kubectl get svc demo-app -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

---

## Cheat Sheet

```bash
# All ArgoCD apps status
kubectl get applications -n argocd

# Force sync without waiting for a push
argocd app sync demo-app
argocd app sync root-app

# Pod status
kubectl get pods -n demo

# Decode any cluster secret
kubectl get secret <name> -n demo -o json \
  | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['data']; [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"

# Validate kustomize overlays before pushing
kustomize build apps/demo-app/overlays/dev

# Migration job logs
kubectl logs -l job-name=demo-app-migration -n demo
kubectl logs -l job-name=demo-app-db-bootstrap -n demo

# Kill postgres port-forward
kill %1
```
