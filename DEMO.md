# GitOps Demo — Presentation Script

Run sections top to bottom. Each section starts with what it shows, then the commands.

---

## What Is This Demo

This demo shows a GitOps workflow built on top of ArgoCD, Kustomize, GitHub Actions, and SealedSecrets. The goal is to prove that the entire lifecycle of an application — deployment, secrets, database schema, permissions — can be managed declaratively from Git, with no manual steps on the cluster after the initial bootstrap.

The demo application is a simple NGINX web app backed by a PostgreSQL database. It is intentionally minimal so the focus stays on the infrastructure patterns, not the application code.

---

## The Application

The app (`app/`) is a single NGINX container serving a static HTML page. It reads two environment variables injected from a Kubernetes Secret:
- `SECRET_MESSAGE` — a message pulled from 1Password
- `TEAM_MESSAGE` — a second message pulled from 1Password

It connects to a PostgreSQL database and the page displays data seeded by the migration job.

---

## Kustomize — Managing Multiple Environments

**What it is:** Kustomize is a Kubernetes-native configuration management tool. Instead of templating (like Helm), it works by layering patches on top of a base configuration. There are no variables or conditionals — just plain YAML with overrides applied per environment.

**How we use it:**
```
apps/demo-app/
  base/                  → shared resources: Deployment, Service, Postgres, Jobs, PDB, NetworkPolicy
  overlays/
    dev/                 → dev-specific: 2 replicas, lower resource limits, sealed secrets, image tag
    stage/               → stage-specific: 2 replicas, sealed secrets
    prod/                → prod-specific: 3 replicas, higher resource limits, no auto self-heal
```

Each overlay references the base and applies patches on top. The image tag is the only thing that changes on every deploy — CI writes the new SHA directly into `overlays/dev/kustomization.yaml` and commits it back to Git.

**Environment differences:**

| Setting | dev | stage | prod |
|---------|-----|-------|------|
| Replicas | 2 | 2 | 3 |
| CPU request | 50m | 50m | 100m |
| RAM limit | 128Mi | 128Mi | 256Mi |
| ArgoCD self-heal | yes | yes | no |

---

## ArgoCD — GitOps Controller

**What it is:** ArgoCD continuously watches a Git repository and ensures the cluster state matches what is in Git. If someone manually changes something on the cluster, ArgoCD reverts it. If Git changes, ArgoCD applies the change.

**Key concepts used:**

- **Application** — tells ArgoCD which repo path to watch and which cluster/namespace to deploy into
- **AppProject** — defines what ArgoCD is allowed to manage: which repos, namespaces, and resource types are permitted. Acts as a security boundary.
- **App of Apps (root-app)** — an ArgoCD Application that watches `clusters/dev/` and manages the AppProject and the demo-app Application themselves. This means even ArgoCD's own configuration is in Git and self-managed.

**Repo structure:**
```
clusters/dev/
  project.yaml      → AppProject: permissions boundary for ArgoCD
  demo-app.yaml     → Application: what to sync and where
bootstrap/
  root-app.yaml     → App of Apps: manages everything above (applied once manually to bootstrap)
```

---

## Sync Waves — Ordered Deployment

**The problem:** PostgreSQL must be running before the migration job can connect. The migration job must complete before the app starts. Kubernetes does not guarantee deployment order on its own.

**The solution:** ArgoCD sync waves. Every resource is annotated with a wave number. ArgoCD deploys wave N and waits for all resources in that wave to be healthy before proceeding to wave N+1.

| Wave | Resource | Why it runs here |
|------|----------|-----------------|
| 0 | Secrets, Services | Must exist before anything else references them |
| 1 | Postgres Deployment | Database must be up and ready |
| 2 | db-bootstrap Job | Creates app-scoped DB user — needs postgres running |
| 3 | Migration Job | Runs schema migrations — needs postgres + the app user |
| 4 | demo-app Deployment | Application starts only after DB is fully ready |

If any wave fails, ArgoCD stops and does not proceed. The app never starts with an unprepared database.

---

## SealedSecrets — Secrets in Git

**The problem:** Kubernetes Secrets are base64-encoded, not encrypted. You cannot commit them to a Git repository safely.

**The solution:** SealedSecrets. A controller running in the cluster holds a private key. You encrypt secrets with the corresponding public key using `kubeseal` — the result is a `SealedSecret` that only this specific cluster can decrypt. The encrypted file is safe to commit to a public repo.

**Our workflow:**
1. Secret values live in 1Password
2. `op read` fetches the value live from 1Password — never written to a file
3. The value is piped directly into `kubeseal` which encrypts it
4. The encrypted `SealedSecret` is committed to Git
5. ArgoCD applies it to the cluster → the SealedSecrets controller decrypts it → a standard Kubernetes Secret is created

Plaintext never touches disk at any point.

**Secrets in this demo:**
- `demo-secret` — app messages (`message`, `team-message`) — sourced from 1Password vault `gitops-demo`
- `app-db-secret` — application DB credentials (`username`, `password`) — sourced from 1Password vault `gitops-demo`
- `postgres-secret` — DB superuser password — plaintext in dev, SealedSecret in stage/prod

---

## CI/CD Pipeline

**CI (GitHub Actions):** triggered on any push to `main` that touches `app/**`
1. Builds a multi-architecture Docker image (linux/amd64 + linux/arm64 — needed because development is on Apple Silicon but production runs on amd64)
2. Pushes the image to GitHub Container Registry (`ghcr.io`)
3. Updates the image tag in `apps/demo-app/overlays/dev/kustomization.yaml` with the new commit SHA
4. Commits the tag change back to `main`

**CD (ArgoCD):** triggered by the CI commit
1. ArgoCD detects the new image tag in Git
2. Runs the full sync wave sequence
3. Rolls out new pods with the updated image

There is no direct connection between CI and ArgoCD. CI writes to Git. ArgoCD reads from Git. Git is the single source of truth.

---

## Architecture Overview (no commands — explain verbally)

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
  root-app.yaml               → The App of Apps — bootstraps everything above
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

## 1. Start from scratch — one command deploys the entire stack

**What this shows:** The whole infrastructure is in Git. One `kubectl apply` bootstraps
everything — ArgoCD creates the AppProject, the Application, and syncs the full stack
with the correct wave order.

```bash
# Clean slate — delete everything
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

## 2. Seal a secret from 1Password — no plaintext ever touches disk

**What this shows:** Secrets are fetched live from 1Password and piped straight into kubeseal.
The only file written to disk is the encrypted SealedSecret — safe to commit to a public repo.

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

## 3. Inspect the database — what the sync waves actually did

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

## 4. Change DB permissions — AppProject update flows through Git

**What this shows:** Previously AppProject changes required manual kubectl apply.
Now root-app manages it — change project.yaml in Git, push, ArgoCD applies it automatically.

```bash
# Example: add a new allowed resource kind to the AppProject
# Edit clusters/dev/project.yaml — add a new entry under namespaceResourceWhitelist:
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

## 5. Add a schema migration — sync waves enforce correct order

**What this shows:** Schema changes are code. Add a migration, push — ArgoCD's sync waves
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
# Change the app (bump to next version — check current first)
grep "GitOps Demo" app/index.html

sed -i '' 's/GitOps Demo — v[0-9]*/GitOps Demo — v6/' app/index.html
grep "v6" app/index.html

git add app/index.html
git commit -m "feat: bump demo to v6"
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

## 7. Rollback — revert to previous version via Git

**What this shows:** Rollback is a git revert. The previous state is in Git history.
Revert the commit, push — ArgoCD rolls back automatically. No special rollback commands.

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
