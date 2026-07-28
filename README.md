# OpenShift CI/CD Pipeline — Reference Implementation

An opinionated, one-command reference build of a **GitOps CI/CD pipeline on
OpenShift**, intended as the working example a customer team can lift and
adapt for their own environment.

> **What this repository is.** The **installer** and **reference
> documentation** for the pipeline pattern.
>
> **What this repository is _not_.** The application source or its Kubernetes
> manifests — those live in GitLab, per the pattern this reference teaches.

## The pattern

```
Developer ── push ──► GitLab (sample-app)
                          │ .gitlab-ci.yml
                          ▼
                     GitLab Runner (on OpenShift)
                          │ buildah
                          ▼
                     JFrog Artifactory (Docker registry)
                          │
                          ▼   (CI's second stage)
                     GitLab (sample-app-gitops) — bump image tag in overlays/dev
                          │
                          ▼   ArgoCD watches, auto-syncs
                     OpenShift — sample-app-dev
                          │
                          │   promotion = MR in sample-app-gitops
                          ▼   changing overlays/prod tag
                     OpenShift — sample-app-prod  (manual/gated sync)
```

## Components deployed by `install.sh`

| Component | Where | Purpose |
|---|---|---|
| OpenShift GitOps operator (ArgoCD) | `openshift-gitops` | Continuous deployment |
| GitLab | `gitlab-system` | Source of truth + CI orchestration |
| GitLab Runner | `gitlab-runner` | Job pods (Kubernetes executor, buildah) |
| Two ArgoCD `Application`s | `openshift-gitops` | One per environment (dev / prod) |
| Two GitLab projects | GitLab | `root/sample-app`, `root/sample-app-gitops` |
| JFrog integration | GitLab CI vars + K8s pull secrets | Push from CI, pull to app namespaces |

## Install

```bash
export GH_PAT=$(cat /path/to/github-pat)          # optional — kept if you back to GitHub
oc login --token=... --server=https://api.<cluster>:6443
./install.sh
```

See **[INSTALL.md](INSTALL.md)** for prerequisites, credentials, and a
step-by-step of what happens.

## Repository layout

```
install.sh                   Idempotent bootstrap. Reads .install-output/creds.
deploy/                      Cluster manifests (SCC, operator subs, Helm values).
docs/                        Architecture diagram + LogQL samples + variables ref.
INSTALL.md                   Prerequisites, run, troubleshooting.
```

Application source and manifests live in GitLab and are created by
`install.sh` in the target GitLab. Their contents are seeded from templates
inside this repo the first time `install.sh` runs.

## For the customer implementation

This reference deploys everything onto a single cluster with in-cluster GitLab
and JFrog Cloud (free tier) for demo compactness. In a real environment:

- Point `install.sh` at your **existing GitLab Enterprise** (skip the in-cluster
  GitLab install and the runner registration will target your GitLab instead).
- Point CI at your **existing JFrog Artifactory** (registry URL + creds only).
- Deploy **ArgoCD in each target cluster** (the operator subscription is the
  same; the `Application`s and `Repository` secret are portable).
- See **[docs/customer-variables.yaml](docs/customer-variables.yaml)** for the
  full list of values you'd substitute.
