# GitOps Demo — Presentation Script

Run sections top to bottom. Each section starts with what it shows, then the commands.

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

# Verify cluster is up
kubectl get nodes

# Start ArgoCD UI port-forward (keep this terminal open)
kubectl port-forward svc/argocd-server -n argocd 8080:80
# UI: http://localhost:8080
```

---

## 1. Start from scratch — one command deploys the entire stack

**What this shows:** The whole infrastructure is in Git. One `kubectl apply` bootstraps
everything — ArgoCD creates the AppProject, the Application, and syncs the full stack
with the correct wave order.

```bash
# Clean slate — delete the running app and namespace
kubectl delete namespace demo --ignore-not-found
argocd app delete demo-app --yes 2>/dev/null || true

# Confirm nothing is running
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
kubeseal --controller-namespace kube-system --fetch-cert > dev-pub.pem

# Seal demo-secret (app message + team message)
kubectl create secret generic demo-secret \
  -n demo \
  --from-literal=message="$(op read 'op://Private/demo-secret/message')" \
  --from-literal=team-message="$(op read 'op://Private/demo-secret/team-message')" \
  --dry-run=client -o yaml \
  | kubeseal --cert dev-pub.pem --format yaml \
  > apps/demo-app/overlays/dev/sealed-secret.yaml

# Seal app-db-secret (app-scoped DB credentials)
kubectl create secret generic app-db-secret \
  -n demo \
  --from-literal=username="$(op read 'op://Private/app-db-secret/username')" \
  --from-literal=password="$(op read 'op://Private/app-db-secret/password')" \
  --dry-run=client -o yaml \
  | kubeseal --cert dev-pub.pem --format yaml \
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
#          echo "005: add demo_version column..."
#          psql -c "ALTER TABLE messages ADD COLUMN IF NOT EXISTS demo_version TEXT DEFAULT 'v1';"

git add apps/demo-app/base/migration-job.yaml
git commit -m "feat: add demo_version column (migration 005)"
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
# Change the app (bump version)
sed -i '' 's/GitOps Demo — v[0-9]*/GitOps Demo — v5/' app/index.html
grep "v5" app/index.html

git add app/index.html
git commit -m "feat: bump demo to v5"
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
