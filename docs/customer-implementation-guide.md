# Customer Implementation Guide

A step-by-step runbook for standing up this GitOps CI/CD pattern in **your**
environment — using your existing **GitLab Enterprise**, **JFrog Artifactory**,
and **OpenShift** — rather than the self-contained demo installer.

It is written to be **run and shared**: every command is explicit, and
[Section 2](#2--exactly-what-gets-created) is a complete inventory of everything
this creates on your cluster and in your GitLab, so your platform and security
teams can review it before anything is applied.

---

## Contents

1. [What this is (and is not)](#1--what-this-is-and-is-not)
2. [Exactly what gets created](#2--exactly-what-gets-created)
3. [Prerequisites you provide](#3--prerequisites-you-provide)
4. [Set your variables](#4--set-your-variables)
5. [Part A — GitLab setup](#5--part-a--gitlab-setup)
6. [Part B — OpenShift setup](#6--part-b--openshift-setup)
7. [Part C — Verify end to end](#7--part-c--verify-end-to-end)
8. [Security notes](#8--security-notes)
9. [Uninstall / rollback](#9--uninstall--rollback)

---

## 1 · What this is (and is not)

The demo ships an `install.sh` that provisions an **in-cluster** GitLab, a
runner, and self-signed TLS. **You will not run that script.** You already have
GitLab Enterprise, JFrog, and (likely) shared runners. This guide performs only
the subset that applies to your environment:

| Demo installer stage | In your environment |
|---|---|
| OpenShift GitOps operator (ArgoCD) | **Install** — or reuse if ArgoCD already runs |
| dev / prod namespaces + JFrog pull secrets | **Create** |
| in-cluster GitLab, custom SCC, self-signed TLS, GitLab Helm install | **Skip** — you have these already, or do them differently |
| GitLab runner registration | **Adapt** — use your existing runner pool |
| GitLab project, seed content, CI variables | **Create** in your GitLab |
| ArgoCD Repository secret, Applications, webhook | **Create** |

The application, its manifests, and the pipeline all live in **one GitLab
project** (a monorepo). **Branches are environments:** the `dev` branch drives
dev, `main` drives prod, and ArgoCD tracks each branch. Committing to `dev`
deploys dev automatically; a reviewed **MR `dev`→`main`** plus a Sync click
deploys prod — and prod runs the exact image dev validated (no rebuild).

---

## 2 · Exactly what gets created

Full inventory, for review before you apply anything.

### On the OpenShift cluster

| Object | Namespace | Purpose | Scope |
|---|---|---|---|
| `Subscription` openshift-gitops-operator | `openshift-operators` | Installs the ArgoCD operator | Cluster-wide (operator) |
| `Namespace` sample-app-dev | — | Dev workloads | — |
| `Namespace` sample-app-prod | — | Prod workloads | — |
| Label `argocd.argoproj.io/managed-by` | on both namespaces | Grants the `openshift-gitops` ArgoCD instance rights **in those two namespaces only** (the operator creates the RoleBindings) | Namespace-scoped |
| `Secret` jfrog-pull (dockercfg) | dev + prod | Lets pods pull images from JFrog | Namespace-scoped |
| `Secret` repo-sample-app (repository) | `openshift-gitops` | ArgoCD's **read-only** clone credential for the GitLab repo | Namespace-scoped |
| `Application` sample-app-dev | `openshift-gitops` | Auto-syncs `gitops/overlays/dev` from the **`dev` branch** | — |
| `Application` sample-app-prod | `openshift-gitops` | Manual-sync `gitops/overlays/prod` from the **`main` branch** | — |
| Key `webhook.gitlab.secret` in `argocd-secret` | `openshift-gitops` | Shared secret so GitLab can trigger a sync | Namespace-scoped |
| `Deployment` / `Service` / `Route` sample-app | dev + prod | The running application (created by ArgoCD from Git) | Namespace-scoped |

**ArgoCD does not receive cluster-admin.** Its access is limited to the two
namespaces you label. Nothing here grants standing privileges outside
`sample-app-dev`, `sample-app-prod`, and `openshift-gitops`.

### In your GitLab

| Object | Purpose |
|---|---|
| One project (`<group>/sample-app`) | App source + gitops manifests + `.gitlab-ci.yml` |
| A long-lived **`dev` branch** | Drives the dev environment; developers commit here. Must survive every merge — see the "keep source branch" note below. |
| Project setting: *remove source branch after merge = OFF* | Keeps the permanent `dev` branch from being deleted when a promotion MR merges |
| 4 CI/CD variables | JFrog registry URL, repo, user, token (masked + protected) |
| Project setting: *CI_JOB_TOKEN allowed to push* | Lets the pipeline commit the image-tag bump back to the repo |
| Protected `main` + MR approval rule | The `dev`→`main` MR is the prod gate; require an approval to merge |
| Read-only deploy token | Consumed by ArgoCD's Repository secret above |
| Project webhook → ArgoCD `/api/webhook` | Instant refresh on pushes to either branch |

### In JFrog

Nothing is *created* by this guide — you push images to a Docker repository you
already own. Images are tagged with the Git commit SHA.

---

## 3 · Prerequisites you provide

Before starting, have these ready (owning team in brackets):

1. **[GitLab admin]** A group and a service/bot account with Maintainer role.
2. **[GitLab admin]** An empty project under that group — you'll seed it.
3. **[JFrog admin]** A Docker repository, plus a **push** technical user (CI) and
   a **read-only** technical user (cluster pull).
4. **[Platform]** OpenShift cluster-admin once (operator install) + namespace-admin ongoing.
5. **[Network]** Egress: cluster → GitLab & JFrog; GitLab → cluster (webhook).
6. **[Security + DevOps]** A decision on the build method — see [Section 8](#8--security-notes).

Tooling on your workstation: `oc`, `git`. (`helm` only if you also install the
runner in-cluster, which most customers do not.)

---

## 4 · Set your variables

Fill these in once; the commands below reference them.

```bash
# --- OpenShift ---
export APPS_DOMAIN="apps.ocp.company.com"          # oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'

# --- GitLab ---
export GITLAB_HOST="gitlab.company.com"            # no scheme
export GITLAB_GROUP="platform-demos"
export GITLAB_PROJECT="sample-app"                 # <group>/<project> is the monorepo
export GITLAB_DEPLOY_TOKEN="<read-only deploy token value>"   # created in Part A, step 5
export GITLAB_DEPLOY_USER="argocd-reader"

# --- JFrog ---
export JFROG_URL="artifactory.company.com"         # host only
export JFROG_REPO="docker-local"                   # Docker repo name
export JFROG_PULL_USER="svc-cluster-pull"
export JFROG_PULL_TOKEN="<read-only jfrog token>"
export IMAGE_REPO="${JFROG_URL}/${JFROG_REPO}/sample-app"
```

---

## 5 · Part A — GitLab setup

**Goal:** a seeded project that builds and pushes to JFrog on the first commit.

### A1 · Seed the project from the reference templates

```bash
git clone https://${GITLAB_HOST}/${GITLAB_GROUP}/${GITLAB_PROJECT}.git
cp -r <reference-repo>/templates/sample-app/. ${GITLAB_PROJECT}/
cd ${GITLAB_PROJECT}

# Point the image at YOUR JFrog in both overlays
sed -i "s|__IMAGE_REPO__|${IMAGE_REPO}|g" \
    gitops/overlays/dev/kustomization.yaml \
    gitops/overlays/prod/kustomization.yaml

# Your GitLab has real TLS — remove the demo's insecure-git flag
# (edit .gitlab-ci.yml, delete the line: GIT_SSL_NO_VERIFY: "true")

git add -A && git commit -m "seed: sample-app monorepo" && git push

# Create the long-lived dev branch (developers work here; drives dev env)
git checkout -b dev && git push -u origin dev
```

The seeded project layout:

```
app/                      application source + Dockerfile
gitops/base/              Deployment, Service, Route
gitops/overlays/dev/      bumped on the `dev` branch; ArgoCD auto-syncs
gitops/overlays/prod/     bumped on `main` (promote); manual-sync, 3 replicas
.gitlab-ci.yml            dev: build -> JFrog -> bump overlays/dev
                          main (on merge): promote dev's tag into overlays/prod
```

**Branches are environments:** `dev` → dev, `main` → prod. Developers commit to
`dev`; promotion is an MR `dev`→`main`.

### A2 · Set the four CI/CD variables

Project → **Settings → CI/CD → Variables** (mark JFROG_TOKEN masked + protected):

| Key | Value |
|---|---|
| `JFROG_URL` | `${JFROG_URL}` |
| `JFROG_REPO` | `${JFROG_REPO}` |
| `JFROG_USER` | (your CI push user) |
| `JFROG_TOKEN` | (your CI push token) |

### A3 · Allow CI_JOB_TOKEN to push

Project → **Settings → CI/CD → Job token permissions** → allow this project to
push to its own repository. Without this, the pipeline's tag-bump commit fails
with `HTTP 403 — You are not allowed to push code`.

### A4 · Protect branches + keep `dev` permanent

Project → **Settings → Repository → Protected branches**: protect `main`
(allow the CI/bot to push, so `promote-prod` can commit the prod tag). Then add
a **merge request approval rule** requiring at least one approval to merge into
`main`. The `dev`→`main` MR is the prod gate — that approval is the audit line.
Leave `dev` unprotected (or allow the CI to push) so `deploy-dev` can commit the
dev tag bump.

> **Critical for this model:** turn **OFF** *Settings → Merge requests →
> "Enable 'Delete source branch' option by default"*. The `dev` branch is
> long-lived — it must survive every promotion merge. GitLab otherwise defaults
> to deleting the source branch, which would destroy `dev` on the first
> promotion. (`install.sh` sets `remove_source_branch_after_merge=false` for you.)

### A5 · Create the read-only deploy token for ArgoCD

Project → **Settings → Repository → Deploy tokens**: name `argocd-reader`,
scope `read_repository`. Copy the token value into `GITLAB_DEPLOY_TOKEN`.

### A6 · Confirm the runner and JFrog

- Your shared runner must be able to pull `quay.io/buildah/stable` and reach JFrog.
- Dry-run from a jump host to prove creds before CI depends on them:
  ```bash
  docker login ${JFROG_URL} -u <ci-push-user> -p <ci-push-token>
  docker pull registry.access.redhat.com/ubi9/ubi:latest
  docker tag  ubi9/ubi:latest ${IMAGE_REPO}:probe
  docker push ${IMAGE_REPO}:probe
  ```

---

## 6 · Part B — OpenShift setup

**Goal:** ArgoCD watching the repo, both Applications registered.

### B1 · Install the OpenShift GitOps operator

```bash
oc apply -f <reference-repo>/deploy/argocd/01-operator-subscription.yaml
```

> **OpenShift 4.12:** edit the Subscription's `channel` to `gitops-1.8` or
> `gitops-1.9` before applying (the committed default targets newer OCP).
> Skip this step entirely if you already run ArgoCD.

Wait for the `openshift-gitops` namespace and its `argocd-server` to be ready:

```bash
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=300s
```

### B2 · Create the two namespaces

```bash
for ns in sample-app-dev sample-app-prod; do
  oc create namespace "$ns"
  oc label namespace "$ns" argocd.argoproj.io/managed-by=openshift-gitops
done
```

The label is what grants ArgoCD rights **in those namespaces only**.

### B3 · Create the JFrog pull secret in each namespace

> Prefer your secrets manager (Vault / External Secrets Operator). The plain
> form is shown for clarity:

```bash
for ns in sample-app-dev sample-app-prod; do
  oc create secret docker-registry jfrog-pull -n "$ns" \
    --docker-server="${JFROG_URL}" \
    --docker-username="${JFROG_PULL_USER}" \
    --docker-password="${JFROG_PULL_TOKEN}" \
    --docker-email="${JFROG_PULL_USER}"
done
```

### B4 · Give ArgoCD read access to the repo

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-sample-app
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://${GITLAB_HOST}/${GITLAB_GROUP}/${GITLAB_PROJECT}.git
  username: ${GITLAB_DEPLOY_USER}
  password: ${GITLAB_DEPLOY_TOKEN}
EOF
```

### B5 · Apply the two Applications

Edit `deploy/argocd/sample-app-dev.yaml` and `sample-app-prod.yaml` so
`repoURL` points at `https://${GITLAB_HOST}/${GITLAB_GROUP}/${GITLAB_PROJECT}.git`,
then:

```bash
oc apply -f <reference-repo>/deploy/argocd/sample-app-dev.yaml
oc apply -f <reference-repo>/deploy/argocd/sample-app-prod.yaml
```

- `sample-app-dev` — tracks the **`dev` branch**, `syncPolicy.automated`
  (prune + selfHeal). Auto-deploys.
- `sample-app-prod` — tracks the **`main` branch**, no `automated` block.
  Deploys only when a human syncs it.

### B6 · Wire the GitLab → ArgoCD webhook (instant sync)

Generate a shared secret and store it in ArgoCD:

```bash
WEBHOOK_SECRET=$(openssl rand -hex 20)
oc patch secret argocd-secret -n openshift-gitops --type merge \
  -p "{\"stringData\":{\"webhook.gitlab.secret\":\"${WEBHOOK_SECRET}\"}}"
oc rollout restart deploy/openshift-gitops-server -n openshift-gitops
echo "ArgoCD host: $(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
echo "Webhook secret: ${WEBHOOK_SECRET}"
```

Then in GitLab → **Settings → Webhooks**: URL
`https://<argocd-host>/api/webhook`, **Push events**, paste the secret token.
(Without the webhook, ArgoCD still deploys — just on its ~3-minute poll instead
of instantly.)

---

## 7 · Part C — Verify end to end

Run these live; they are also the best demo scenarios.

**1 — Full flow (dev):**
```bash
# On the dev branch: edit app/app.py, then
git commit -am "test: change message" && git push origin dev
```
Watch: `build-image` → JFrog, `deploy-dev` bumps `overlays/dev` on the `dev`
branch → ArgoCD (tracking `dev`) auto-syncs →
`https://sample-app-sample-app-dev.${APPS_DOMAIN}` shows the new commit SHA.

**2 — Promotion to prod:** open an **MR `dev`→`main`**, approve, merge —
**leave "Delete source branch" unchecked** so `dev` survives. The `promote-prod`
job (ref=main) copies dev's image tag into `overlays/prod` — no rebuild. Then
sync `sample-app-prod` in the ArgoCD UI (or `oc patch application sample-app-prod
-n openshift-gitops --type=merge -p '{"operation":{"sync":{"revision":"main"}}}'`).
Note `build-image` does **not** run on `main` — prod gets the exact image dev ran.

**3 — Rollback:** `git revert` the promotion MR on `main`, sync prod. Recovery
uses the same path as delivery.

**4 — Self-heal:** `oc scale deploy/sample-app -n sample-app-dev --replicas=5`
and watch ArgoCD revert it.

**5 — Broken build blocked:** push code that fails the build; confirm nothing
reaches the cluster.

**6 — Loki:** run a query from [`logql-queries.md`](logql-queries.md) — e.g.
"which pod served commit X".

---

## 8 · Security notes

**Build execution.** The reference builds images with `buildah` under
`privileged: true`. Your cluster policy may forbid this. Options, most to least
preferred on a locked-down cluster:

1. **Kaniko** — rootless, daemonless. Usually the cleanest fit.
2. **OpenShift Shipwright / BuildConfig** — the platform builds; the runner
   holds no elevated privilege.
3. Privileged `buildah` on a **dedicated, tainted node pool**, isolated from
   application workloads.

Decide this in prerequisites, not during the build session.

**Secrets.** Route the JFrog pull secret and the CI variables through your
secrets manager (Vault / External Secrets Operator) so they rotate without
touching pipeline configs. The plain `oc create secret` form in Part B is for
clarity only.

**Least privilege.** ArgoCD's cluster footprint is the two labelled namespaces
plus its own `openshift-gitops` namespace — no cluster-admin. The GitLab CI
push uses the built-in, per-pipeline `CI_JOB_TOKEN` (no long-lived credential).
ArgoCD's repo access is a **read-only** deploy token.

---

## 9 · Uninstall / rollback

Everything this guide creates can be removed cleanly:

```bash
# ArgoCD Applications (also removes the workloads they manage)
oc delete application sample-app-dev sample-app-prod -n openshift-gitops

# ArgoCD repo secret + webhook secret key
oc delete secret repo-sample-app -n openshift-gitops
oc patch secret argocd-secret -n openshift-gitops --type=json \
  -p '[{"op":"remove","path":"/data/webhook.gitlab.secret"}]' 2>/dev/null || true

# Namespaces (removes pull secrets + any workloads)
oc delete namespace sample-app-dev sample-app-prod

# The OpenShift GitOps operator — only if YOU installed it and nothing else uses it
oc delete -f <reference-repo>/deploy/argocd/01-operator-subscription.yaml
```

On the GitLab side: delete the project, its CI variables, deploy token, and
webhook. On JFrog: delete any pushed `sample-app` image tags. Nothing persists
outside these objects.
