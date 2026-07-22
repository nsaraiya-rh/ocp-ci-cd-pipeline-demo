# OpenShift CI/CD Pipeline Demo

End-to-end GitOps CI/CD on OpenShift using **GitLab** (CI), **ArgoCD / OpenShift
GitOps** (CD), the **OpenShift internal registry** (images), and **GitHub** as
the source of truth.

> **Deploying to a cluster?** Run `./install.sh` — see **[INSTALL.md](INSTALL.md)**.
> It provisions everything below on any OpenShift cluster (nothing is hardcoded).

## Flow

```
Developer ── push (sample-app/**) ──▶ GitHub (this repo)
                                          │ GitHub Action: mirror-to-gitlab
                                          ▼
                                 GitLab project root/sample-app
                                          │ CI pipeline (.gitlab-ci.yml)
                                          ├─ build-image:    buildah build → push to
                                          │                  OpenShift internal registry
                                          └─ update-manifest: bump tag in gitops/kustomization.yaml
                                                             (commit back to GitHub) ──┐
                                                                                       ▼
                                 ArgoCD (OpenShift GitOps) watches gitops/ ── sync ──▶ deploy to
                                                                                       sample-app namespace
```

- A push touching `sample-app/**` triggers the GitHub Action, which mirrors the
  repo to GitLab and starts the pipeline.
- The pipeline's tag-bump commit only touches `gitops/**`, so the Action's path
  filter skips it — **no build loop**.

## Repository layout

| Path | Purpose |
|------|---------|
| `sample-app/` | Application source (Flask), `Dockerfile`. Edit here to trigger the pipeline. |
| `.gitlab-ci.yml` | GitLab pipeline: build image → push to registry → bump gitops tag. |
| `.github/workflows/mirror-to-gitlab.yml` | Mirrors pushes to GitLab (the CI trigger). |
| `gitops/` | Kustomize manifests ArgoCD deploys (`Deployment`, `Service`, `Route`). CI updates the image tag here. |
| `deploy/` | One-time cluster setup (applied by a cluster admin). |
| `deploy/argocd/` | OpenShift GitOps operator subscription + the ArgoCD `Application`. |
| `deploy/gitlab/` | GitLab operator subscription, `GitLab` CR, runner Helm values. |
| `deploy/registry/` | `sample-app` namespace, image-push service account + token. |

## Cluster components (already deployed)

| Component | How |
|-----------|-----|
| ArgoCD | OpenShift GitOps operator (`openshift-gitops` namespace) |
| GitLab | GitLab operator, chart 9.11.7 (GitLab 17.x), self-signed TLS via OpenShift Routes at `gitlab.apps.<domain>` |
| GitLab Runner | Helm chart 0.76.x, Kubernetes executor, privileged (buildah) |
| Image registry | OpenShift internal registry; images at `image-registry.openshift-image-registry.svc:5000/sample-app/sample-app` |

## Required secrets / variables

**GitLab project `root/sample-app` → Settings > CI/CD > Variables**
| Key | Value |
|-----|-------|
| `REGISTRY_USER` | `gitlab-pusher` |
| `REGISTRY_TOKEN` | OpenShift token for SA `sample-app/gitlab-pusher` |
| `GITHUB_TOKEN` | GitHub PAT (`repo` scope) to push the tag bump |

**GitHub repo → Settings > Secrets and variables > Actions**
| Key | Value |
|-----|-------|
| `GITLAB_PUSH_TOKEN` | GitLab token that can push to `root/sample-app` |

## Try it

Edit the message in [`sample-app/app.py`](sample-app/app.py), commit, and push to
`main`. Watch the GitLab pipeline run, then ArgoCD sync the new image. The app is
exposed at `https://sample-app-sample-app.apps.<cluster-domain>`.
