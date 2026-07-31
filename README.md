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

Monorepo — **one GitLab project** holds application source, CI pipeline, and
deployment manifests. **Branches are environments**: the `dev` branch drives the
dev environment, `main` drives prod. ArgoCD tracks each branch.

```
Developer ── commit to `dev` branch ──►  GitLab (sample-app monorepo)
                            ├── app/                    source, Dockerfile
                            ├── gitops/base/            shared manifests
                            ├── gitops/overlays/dev/    ← bumped on the dev branch
                            ├── gitops/overlays/prod/   ← bumped on main (promote)
                            └── .gitlab-ci.yml
                            │
   ┌────────────────────────┴─ on commit to `dev` ─────────────────────────┐
   │ build-image  → buildah → JFrog Artifactory  :<commit sha>              │
   │ deploy-dev   → bump overlays/dev on `dev` branch                       │
   └────────────────────────────────┬──────────────────────────────────────┘
                                     ▼  ArgoCD (tracks `dev`) auto-syncs
                              OpenShift — sample-app-dev

   ── open MR `dev` → `main`, review, merge ──►

   ┌──────────────── on merge to `main` ────────────────────────────────────┐
   │ promote-prod → copy dev's image tag into overlays/prod  (NO rebuild)    │
   └────────────────────────────────┬──────────────────────────────────────┘
                                     ▼  ArgoCD (tracks `main`) → OutOfSync
                              a human clicks Sync
                                     ▼
                              OpenShift — sample-app-prod
```

**Why branches as environments:** dev deploys automatically from the `dev`
branch, while reaching prod requires a reviewed **MR `dev`→`main`** *and* a
deliberate Sync click — two gates. Prod always runs the **exact image** dev
validated; `promote-prod` copies the tag, it never rebuilds.

## Components deployed by `install.sh`

| Component | Where | Purpose |
|---|---|---|
| OpenShift GitOps operator (ArgoCD) | `openshift-gitops` | Continuous deployment |
| GitLab | `gitlab-system` | Source of truth + CI orchestration |
| GitLab Runner | `gitlab-runner` | Job pods (Kubernetes executor, buildah) |
| Two ArgoCD `Application`s | `openshift-gitops` | One per environment (dev / prod) |
| One GitLab project | GitLab | `root/sample-app` (monorepo) |
| JFrog integration | GitLab CI vars + K8s pull secrets | Push from CI, pull to app namespaces |

## Install

```bash
export JFROG_CREDS_FILE=~/.config/ocp-clusters/jfrog-creds.txt
oc login --token=... --server=https://api.<cluster>:6443
./install.sh
```

See **[INSTALL.md](INSTALL.md)** for prerequisites, credentials, and a
step-by-step of what happens.

## Repository layout

```
install.sh                   Idempotent bootstrap. Reads JFROG_CREDS_FILE.
deploy/                      Cluster manifests (SCC, operator subs, Helm values,
                             ArgoCD Applications for dev + prod).
templates/sample-app/        Seed content for the GitLab project — pushed at
                             install time. This IS what the customer's team
                             will lift and adapt (rename, rewire).
docs/                        Architecture diagram, LogQL query samples,
                             customer variables reference.
INSTALL.md                   Prereqs, run, troubleshooting.
```

## Why monorepo

- **One credential surface** — CI push-back to the gitops overlay uses the
  built-in `CI_JOB_TOKEN`. No cross-project access tokens, no rotation.
- **One webhook, one Repository secret** in ArgoCD.
- **Simpler for small teams** — everything an app owns lives in one place.

The alternative — **split repos** (source repo + gitops repo) — is often the
right call at scale, because it lets MR approval rules structurally enforce
"prod deploy requires SRE sign-off". Ask when it applies to the target env.

## For the customer implementation

This reference deploys onto a single cluster with in-cluster GitLab and JFrog
Cloud (free tier) for demo compactness. In a real environment:

- Point CI at your **existing GitLab Enterprise** (skip the in-cluster GitLab
  install; runner registration targets your GitLab instead).
- Point CI at your **existing JFrog Artifactory** (registry URL + creds only).
- Deploy **ArgoCD in each target cluster** (same operator subscription).
- See **[docs/customer-variables.yaml](docs/customer-variables.yaml)** for the
  full list of values you'd substitute.
