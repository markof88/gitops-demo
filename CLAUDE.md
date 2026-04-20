# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A GitOps demo using ArgoCD + Kustomize for multi-environment Kubernetes deployments. There is no application test suite or Makefile — the "build" is the GitHub Actions pipeline and the "deployment" is ArgoCD syncing from this repo.

## Key Commands

**Validate Kustomize overlays locally (requires kustomize v5.4.1):**
```bash
kustomize build apps/demo-app/overlays/dev
kustomize build apps/demo-app/overlays/stage
kustomize build apps/demo-app/overlays/prod
```

**Seal a new secret for an environment (requires kubeseal + cluster access):**
```bash
# Fetch the environment's cert first
kubeseal --controller-namespace kube-system --fetch-cert > <env>-pub.pem

# Seal a secret
kubeseal --format yaml --cert <env>-pub.pem < raw-secret.yaml > sealed-secret.yaml
```

**Update image tag in dev overlay (what CI does automatically):**
```bash
cd apps/demo-app/overlays/dev
kustomize edit set image demo-app=ghcr.io/<owner>/demo-app:<sha>
```

## Architecture

### GitOps Flow

```
Push to main (app/** changed)
  → GitHub Actions builds multi-platform Docker image (linux/amd64 + linux/arm64)
  → Pushes to ghcr.io/<repo>/demo-app:<sha>
  → Updates apps/demo-app/overlays/dev/kustomization.yaml with new image tag
  → Commits back to main
  → ArgoCD (dev) auto-syncs → deploys new image
  → Stage/prod require manual image tag update + re-sealing secrets if needed
```

### Directory Layout

- `app/` — NGINX demo app source (Dockerfile + index.html)
- `apps/demo-app/base/` — Kustomize base resources shared by all environments
- `apps/demo-app/overlays/{dev,stage,prod}/` — Environment-specific patches and secrets
- `clusters/{dev,stage,prod}/` — ArgoCD `Application` and `AppProject` manifests

### Database Sync Wave Order (ArgoCD)

Resources deploy in this order via `argocd.argoproj.io/sync-wave`:

| Wave | Resource | Purpose |
|------|----------|---------|
| -1 | `migration-configmap` (PreSync hook) | Load migration SQL |
| 1 | `postgres` deployment | Database up |
| 2 | `demo-app-db-bootstrap` job (sync hook) | Create app-scoped DB user, grant permissions |
| 3 | `demo-app-migration` job (sync hook) | Run schema migrations + seed data |
| 4 | `demo-app` deployment | Application |

### Environment Differences

| Setting | dev | stage | prod |
|---------|-----|-------|------|
| Replicas | 2 | 2 | 3 |
| CPU request | 50m | 50m | 100m |
| RAM limit | 128Mi | 128Mi | 256Mi |
| postgres-secret | Plaintext | SealedSecret | SealedSecret |
| ArgoCD self-heal | Yes | Yes | **No** |
| ArgoCD auto-sync | Yes | Yes | Yes |

### Secrets Strategy

- `demo-secret` — App secrets (`SECRET_MESSAGE`, `TEAM_MESSAGE`) — SealedSecret in all envs
- `postgres-secret` — DB superuser password — plaintext in dev, SealedSecret in stage/prod
- `app-db-secret` — App-scoped DB credentials — SealedSecret in all envs

SealedSecrets are encrypted per-cluster. Never copy a SealedSecret from one environment to another; always re-seal with the target cluster's certificate.
