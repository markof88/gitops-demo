# GitOps Demo

---

## What Is This Demo

This demo shows a GitOps workflow built on ArgoCD, Helm, ApplicationSet, GitHub Actions, and SealedSecrets. The goal is to prove that the entire lifecycle of an application — deployment, secrets, database schema, permissions — can be managed declaratively from Git, with no manual steps on the cluster after the initial bootstrap.

The demo runs two services deployed from a single generic Helm chart (`caralegal-service`), managed by an ApplicationSet. It mirrors how Caralegal's ~50 microservices would be structured in a real GitOps platform.

---

## Repository Structure

```
gitops-demo/
  app/                        → application source code (built into a Docker image)
  charts/caralegal-service/   → one generic Helm chart, reused for every service
  services/
    demo-app/
      values-dev.yaml         → demo-app specific values (image, env, db, migrations)
      secrets/                → SealedSecrets applied as raw YAML by ArgoCD
    orgunit-mock/
      values-dev.yaml         → orgunit-mock specific values (stateless service)
      secrets/
  bootstrap/
    applicationset.yaml       → ApplicationSet: one template, manages all services
  clusters/dev/
    project.yaml              → ArgoCD AppProject (permissions boundary)
  .github/workflows/
    build-deploy.yml          → CI pipeline (GitHub Actions)
```

---

## `app/` The Application Source Code

```
app/
  Dockerfile      → builds an NGINX image, copies index.html into it
  index.html      → static HTML page served by NGINX
```

Intentionally trivial. The interesting part is everything around it, not the app itself.

**What triggers a build:** GitHub Actions watches for any push to `main` that touches `app/**`. Changes to `charts/`, `services/`, or `bootstrap/` do not trigger a build.

---

## `charts/caralegal-service/` The Generic Helm Chart

One chart acts as a mold for every microservice. The same chart is reused for every service — what changes is the values file poured into it.

```
charts/caralegal-service/
  Chart.yaml
  values.yaml                 → defaults (all features disabled by default)
  templates/
    deployment.yaml           → sync-wave: "4"
    service.yaml
    postgres.yaml             → sync-wave: "1" (only if postgres.enabled: true)
    postgres-netpol.yaml
    db-bootstrap-job.yaml     → sync-wave: "2" (only if dbBootstrap.enabled: true)
    migration-job.yaml        → sync-wave: "3" (only if migrations.enabled: true)
    pdb.yaml
    extra-objects.yaml
```

**Sync wave order (runs on every sync):**
| Wave | Resource | Purpose |
|------|----------|---------|
| 1 | postgres | wait for DB to be ready |
| 2 | db-bootstrap job | create app-scoped DB user, grant permissions |
| 3 | migration job | run schema migrations, seed data |
| 4 | deployment | application starts last, DB is guaranteed ready |

---

## `services/` Per-Service Configuration

Each service has exactly two things: a values file and a secrets directory.

### `services/demo-app/values-dev.yaml`
Full-featured service: postgres, db-bootstrap, migrations, env vars from secrets.

### `services/orgunit-mock/values-dev.yaml`
Stateless service: no database, only env vars and one secret. Demonstrates that the same chart works for completely different service profiles.

**Same chart. Completely different behavior. That is the point.**

### `services/demo-app/secrets/`
SealedSecrets applied as raw YAML by ArgoCD (separate source in ApplicationSet). Kept outside Helm to avoid base64 encoding issues with the Go strict decoder.

- `app-db-sealed-secret.yaml` — app-scoped DB credentials (`username`, `password`)
- `sealed-secret.yaml` — app messages (`message`, `team-message`)

---

## `bootstrap/applicationset.yaml` The Factory

One template, produces one ArgoCD Application per service in the list.

```yaml
generators:
- list:
    elements:
    - service: demo-app
      namespace: demo
    - service: orgunit-mock
      namespace: orgunit-mock
```

Adding a third service: add one line to the list. ArgoCD creates the Application, creates the namespace, and syncs the chart automatically.

Each Application gets three sources:
1. `charts/caralegal-service` — the Helm chart
2. `services/{{service}}/secrets` — raw SealedSecrets
3. `services/{{service}}/values-dev.yaml` — values via `$values` ref

---

## `.github/workflows/build-deploy.yml` The CI Pipeline

**Trigger:** push to `main` where files under `app/` changed.

**What it does:**
1. Builds a multi-arch image (`linux/amd64` + `linux/arm64`)
2. Pushes to GitHub Container Registry tagged with the commit SHA
3. Updates the image tag in `services/demo-app/values-dev.yaml`:
   ```bash
   sed -i "s|tag:.*|tag: ${{ github.sha }}|" services/demo-app/values-dev.yaml
   ```
4. Commits `deploy: update demo-app to <SHA>` back to `main`

**CI never touches the cluster.** It only writes to Git. ArgoCD reads from Git. That is the entire handoff.

---

## How It All Fits Together

```
1. Developer pushes a change to app/index.html
       ↓
2. GitHub Actions detects the push (paths: app/**)
   - builds multi-arch Docker image
   - pushes to ghcr.io with the commit SHA as tag
   - updates services/demo-app/values-dev.yaml with new tag
   - commits "deploy: update demo-app to <SHA>" back to main
       ↓
3. ArgoCD detects the new commit (polls every 30s)
   - compares desired state (Git) vs actual state (cluster)
   - detects the image tag changed
   - runs the sync wave sequence:
       wave 1: postgres (waits until healthy)
       wave 2: db-bootstrap job (runs, waits until complete)
       wave 3: migration job (runs, waits until complete)
       wave 4: demo-app deployment (rolls out with new image)
       ↓
4. New pods are running the new image. Rollout complete.
   CI never touched the cluster. The cluster state matches Git exactly.
```

---

## 0. Prerequisites

```bash
# Verify tools
kubectl version --client
argocd version --client
kubeseal --version
op --version

# Verify cluster is up
kubectl get nodes

# Login to ArgoCD CLI
argocd login localhost:8080 --insecure --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d)"

# App URL — LoadBalancer IP, no port-forward needed
kubectl get svc demo-app -n demo
# Open: http://172.18.255.254
```

---

## 1. Bootstrap — one command deploys the entire stack

**What this shows:** The whole infrastructure is in Git. Apply the ApplicationSet once, ArgoCD creates both Applications, creates namespaces, and syncs the full stack in wave order.

```bash
# Clean slate
kubectl delete applicationset caralegal-dev -n argocd --ignore-not-found
kubectl delete namespace demo --ignore-not-found
kubectl delete namespace orgunit-mock --ignore-not-found

# Confirm nothing is running
kubectl get applications -n argocd

# Bootstrap — the only kubectl apply you ever need to run
kubectl apply -f clusters/dev/project.yaml
kubectl apply -f bootstrap/applicationset.yaml

# ArgoCD creates demo-app and orgunit-mock Applications automatically
# Watch the sync wave sequence for demo-app
kubectl get pods -n demo -w
kubectl get jobs -n demo -w
```

```bash
# Confirm everything is up
kubectl get all -n demo
kubectl get applications -n argocd

# Open the app
open http://172.18.255.254
```

---

## 2. Seal a secret from 1Password — plaintext never touches disk

**What this shows:** Secrets are fetched live from 1Password and piped straight into kubeseal. The only file written to disk is the encrypted SealedSecret, safe to commit to a public repo.

```bash
# Sign in to 1Password
eval $(op signin)

# Fetch the cluster's public cert (safe to share — it is a public key)
kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --fetch-cert > ./dev-pub.pem

# Seal demo-secret (app message + team message)
# op read fetches from 1Password into memory — never touches disk
kubectl create secret generic demo-secret \
  -n demo \
  --from-literal=message="$(op read 'op://gitops-demo/demo-secret/message')" \
  --from-literal=team-message="$(op read 'op://gitops-demo/demo-secret/team-message')" \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --cert ./dev-pub.pem \
  --format yaml \
> services/demo-app/secrets/sealed-secret.yaml

# Seal app-db-secret (app-scoped DB credentials)
kubectl create secret generic app-db-secret \
  -n demo \
  --from-literal=username="demo_app" \
  --from-literal=password="$(op read 'op://gitops-demo/demo-app-db/password')" \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --cert ./dev-pub.pem \
  --format yaml \
> services/demo-app/secrets/app-db-sealed-secret.yaml

# Show the file — only encrypted blob, no plaintext
cat services/demo-app/secrets/sealed-secret.yaml

# Commit and push — ArgoCD applies the new SealedSecrets automatically
git add services/demo-app/secrets/
git commit -m "chore: rotate dev sealed secrets"
git push origin main
```

**The chain:**
1Password → fetched into memory → encrypted by kubeseal → committed to Git as blob → ArgoCD applies it → SealedSecrets controller decrypts → Kubernetes Secret created → pod reads as env var.

The actual secret value exists in exactly two places: 1Password and inside the running pod.

---

## 3. Inspect the database — what sync waves actually did

**What this shows:** Wave 2 (db-bootstrap) created an app-scoped DB user with limited privileges. Wave 3 (migration) created the schema and seeded data. Both ran automatically on sync, in order.

```bash
# Check which jobs ran
kubectl get jobs -n demo

# Migration job logs — every SQL statement
kubectl logs -n demo -l job-name=demo-app-migration --tail=50

# Connect to postgres directly
kubectl exec -it -n demo statefulset/postgres -- psql -U demo -d demo

# Inside psql:
\dt                        -- tables created by migration job (wave 3)
\du                        -- roles: demo (superuser) + demo_app (app-scoped, wave 2)
SELECT * FROM messages;    -- seeded row
\d messages                -- all columns added by migrations
\q
```

```bash
# Connect as the app-scoped user (created by db-bootstrap, wave 2)
# This user has no superuser privileges — only what it needs
export APP_USER=$(kubectl get secret app-db-secret -n demo \
  -o jsonpath='{.data.username}' | base64 -d)
export APP_PASS=$(kubectl get secret app-db-secret -n demo \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -it -n demo statefulset/postgres -- \
  env PGPASSWORD=$APP_PASS psql -U $APP_USER -d demo -c "SELECT * FROM messages;"
```

---

## 4. Code change → CI builds image → ArgoCD rolls out

**What this shows:** The full GitOps loop. Push app code, CI builds and pushes the image, commits the new tag back to Git, ArgoCD detects the change and rolls out new pods.

```bash
# Change the app
sed -i '' 's/v[0-9]*/v9/' app/index.html

git add app/index.html
git commit -m "feat: bump demo to v9"
git push origin main

# If the remote has a new CI commit, rebase first
git pull --rebase origin main && git push origin main

# Watch GitHub Actions build and push the image
gh run watch

# ArgoCD detects the new tag commit and rolls out
kubectl rollout status deployment/demo-app -n demo

# Confirm the new version is live
open http://172.18.255.254
```

---

## 5. Drift detection and self-heal

**What this shows:** Manual changes to the cluster are detected and reverted. Git is the only source of truth.

```bash
# First disable auto-sync so drift persists long enough to show
kubectl patch applicationset caralegal-dev -n argocd \
  --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/syncPolicy/automated"}]'

# Manually scale to 5 replicas — this is NOT in Git
kubectl scale deployment demo-app -n demo --replicas=5
kubectl get pods -n demo   # shows 5 pods

# ArgoCD UI shows: OutOfSync
# "The cluster drifted from Git"

# Manually sync to reconcile — ArgoCD restores Git state
argocd app sync demo-app
kubectl get pods -n demo   # back to 2

# Restore auto-sync
kubectl apply -f bootstrap/applicationset.yaml
```

---

## 6. Rollback via ArgoCD UI

**What this shows:** Every deployment is recorded. Rollback redeploys a previous exact state in ~15 seconds.

In ArgoCD UI:
1. Open **demo-app** Application
2. Click **History and Rollback** (clock icon)
3. Pick any previous entry → **Rollback**

The app at `http://172.18.255.254` shows the old version immediately.

Via CLI:
```bash
# See all deployments
argocd app history demo-app

# Rollback to a specific revision
argocd app rollback demo-app <revision-number>
```

---

## 7. Add a service — one line in ApplicationSet

**What this shows:** Onboarding a new service requires no pipeline changes, no new ArgoCD config files, no manual cluster work. One line in the ApplicationSet list.

```yaml
# In bootstrap/applicationset.yaml, add:
- service: billing-service
  namespace: billing
```

```bash
git add bootstrap/applicationset.yaml
git commit -m "feat: add billing-service to ApplicationSet"
git push origin main

# ArgoCD creates the Application automatically, creates the namespace,
# syncs the chart with the values from services/billing-service/values-dev.yaml
kubectl get applications -n argocd
```

---

## Cheat Sheet

```bash
# All applications status
kubectl get applications -n argocd

# Force sync
argocd app sync demo-app

# Pod status
kubectl get pods -n demo
kubectl get pods -n orgunit-mock

# Job logs
kubectl logs -n demo -l job-name=demo-app-migration --tail=50
kubectl logs -n demo -l job-name=demo-app-db-bootstrap --tail=50

# Decode any cluster secret
kubectl get secret <name> -n demo -o json \
  | python3 -c "import sys,json,base64; \
    d=json.load(sys.stdin)['data']; \
    [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"

# App URL
kubectl get svc demo-app -n demo
# http://172.18.255.254

# Validate Helm chart locally before pushing
helm template demo-app charts/caralegal-service \
  -f services/demo-app/values-dev.yaml
```
