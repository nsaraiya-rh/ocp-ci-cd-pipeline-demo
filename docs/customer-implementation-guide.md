# Customer Implementation Guide

A step-by-step runbook for standing up this GitOps CI/CD pattern in **your**
environment — using your existing **GitLab Enterprise**, **JFrog Artifactory**,
and **OpenShift** — with **per-branch preview environments** for dev and a gated
promotion to prod.

It is written to be **run and shared**: every command is explicit, and
[Section 2](#2--exactly-what-gets-created) is a complete inventory of everything
this creates on your cluster and in your GitLab, so your platform and security
teams can review it before anything is applied.

> **Which model is this?** This guide describes the **preview-environment**
> model: each feature branch gets its own live deployment in a shared namespace,
> and merging to `main` promotes the tested image to prod. The reference repo
> also ships a simpler **shared-dev** model (one dev environment, driven by a
> long-lived `dev` branch); if you want that instead, use
> `templates/sample-app/.gitlab-ci.yml`. This guide is the preview flow.

---

## Contents

1. [What this is (and is not)](#1--what-this-is-and-is-not)
2. [Exactly what gets created](#2--exactly-what-gets-created)
3. [Prerequisites you provide](#3--prerequisites-you-provide)
4. [Set your variables](#4--set-your-variables)
5. [Part A — Foundation: seed the repository](#5--part-a--foundation-seed-the-repository)
6. [Part B — CD: OpenShift + Argo CD](#6--part-b--cd-openshift--argo-cd)
7. [Part C — CI: the GitLab pipeline](#7--part-c--ci-the-gitlab-pipeline)
8. [Part D — Verify end to end](#8--part-d--verify-end-to-end)
9. [Security notes](#9--security-notes)
10. [Uninstall / rollback](#10--uninstall--rollback)

---

## 1 · What this is (and is not)

You already have **GitLab Enterprise**, **JFrog Artifactory**, and (likely)
shared runners, so you do **not** stand any of those up. This guide performs only
the subset that applies to your environment:

| Component | In your environment |
|---|---|
| OpenShift GitOps operator (ArgoCD) | **Install** — or reuse if ArgoCD already runs |
| dev / prod namespaces + JFrog pull secrets | **Create** |
| GitLab, custom SCC, TLS | **Skip** — you have these already |
| GitLab runner registration | **Adapt** — use your existing runner pool |
| GitLab project, seed content, CI variables | **Create** in your GitLab |
| ArgoCD repository secret, **preview ApplicationSet + prod Application**, webhook | **Create** |

The application, its manifests, and the pipeline all live in **one GitLab
project** (a monorepo). The model is:

- **Push any feature branch → its own preview environment.** The preview
  ApplicationSet watches branches and deploys `sample-app-<branch-slug>` into the
  shared `sample-app-dev` namespace, each with its own URL. Developers test their
  branch in isolation. No merge request is required for a preview.
- **Merge an MR into `main` → prod.** A reviewed, approved MR (merged as a
  **merge commit**) triggers `promote-prod`, which copies the **exact tested
  image** into `overlays/prod`. A human then clicks **Sync** in ArgoCD. Prod
  never rebuilds — it runs the byte-for-byte image validated in the preview.
- **Delete the branch → the preview is torn down** automatically.

Images are built with **Kaniko** (unprivileged) so the pipeline runs on
locked-down Kubernetes runners.

### Order of operations — CD before CI

Set up in this order (the more GitOps-idiomatic sequence — destination and
reconciler first, then the thing that feeds them):

1. **Part A — seed the repository** (shared foundation for CI and CD).
2. **Part B — CD (ArgoCD):** prod Application + the preview ApplicationSet.
   Afterward there are no previews yet (none pushed) and prod is empty — expected.
3. **Part C — CI:** the pipeline that builds images.
4. **Part D — verify:** push a branch, watch its preview, promote to prod.

---

## 2 · Exactly what gets created

Full inventory, for review before you apply anything.

### On the OpenShift cluster

| Object | Namespace | Purpose | Scope |
|---|---|---|---|
| `Subscription` openshift-gitops-operator | `openshift-operators` | Installs the ArgoCD operator | Cluster-wide (operator) |
| `Namespace` sample-app-dev | — | **All** preview deployments live here | — |
| `Namespace` sample-app-prod | — | Prod workloads | — |
| Label `argocd.argoproj.io/managed-by` | on both namespaces | Grants the `openshift-gitops` ArgoCD instance rights **in those two namespaces only** | Namespace-scoped |
| `Secret` jfrog-pull (dockercfg) | dev + prod | Lets pods pull images from JFrog | Namespace-scoped |
| `Secret` repo-sample-app (repository) | `openshift-gitops` | ArgoCD's **read-only** clone credential | Namespace-scoped |
| `Secret` gitlab-scm-token | `openshift-gitops` | **read-only** GitLab API token so the branch generator can list branches | Namespace-scoped |
| `ApplicationSet` sample-app-preview | `openshift-gitops` | One Application per matching branch → `sample-app-<branch-slug>` in `sample-app-dev` | — |
| `Application` sample-app-prod | `openshift-gitops` | Manual-sync `gitops/overlays/prod` from the **`main` branch** | — |
| Key `webhook.gitlab.secret` in `argocd-secret` | `openshift-gitops` | Shared secret so GitLab can trigger a sync | Namespace-scoped |
| `Deployment`/`Service`/`Route` sample-app-<branch> | dev | A preview per branch (created by ArgoCD from Git) | Namespace-scoped |
| `Deployment`/`Service`/`Route` sample-app | prod | The production app | Namespace-scoped |

**ArgoCD does not receive cluster-admin.** Its access is limited to the two
namespaces you label plus its own `openshift-gitops` namespace.

### In your GitLab

| Object | Purpose |
|---|---|
| One project (`<group>/sample-app`) | App source + gitops manifests + `.gitlab-ci.yml` |
| **No long-lived branch** | Previews come and go with feature branches; there is no permanent `dev` branch |
| Read-only **deploy token** (`read_repository`) | ArgoCD's repository clone credential |
| Read-only **API token** (`read_api`) | The branch generator lists branches with this |
| 4 CI/CD variables | JFrog registry URL, repo, user, token (masked + protected) |
| Setting: *CI_JOB_TOKEN allowed to push* | Lets `promote-prod` commit the prod tag bump |
| Setting: *merge method = **Merge commit*** | `promote-prod` reads the tested image from the merge commit's 2nd parent |
| Setting: *Delete source branch after merge = **ON*** | Tearing the branch down removes its preview |
| Protected `main` + MR approval rule | The MR into `main` is the prod gate |
| Project webhook → ArgoCD `/api/webhook` | Instant refresh on pushes (optional) |

### In JFrog

Nothing is *created* by this guide — you push images to a Docker repository you
already own. Images are tagged with the Git commit SHA (full and short).

---

## 3 · Prerequisites you provide

Before starting, have these ready (owning team in brackets):

1. **[GitLab admin]** A group and a service/bot account with Maintainer role.
2. **[GitLab admin]** An empty project under that group — you'll seed it.
3. **[JFrog admin]** A Docker repository, plus a **push** technical user (CI) and
   a **read-only** technical user (cluster pull).
4. **[Platform]** OpenShift cluster-admin once (operator install) + namespace-admin ongoing.
5. **[Network]** The connectivity below — confirm it before seeding.
6. **[Security + DevOps]** A decision on the build method — see [Section 9](#9--security-notes). (This guide uses Kaniko.)

Tooling on your workstation: `oc`, `git`.

### Network connectivity (hand this to the network team)

Most first-run failures are a blocked port, not a config error. Four actors talk
to each other: **GitLab**, the **Runner** (build jobs), the **OpenShift cluster**
(ArgoCD + the nodes that pull images), and **JFrog**.

| # | From | To | Port | Purpose | Required |
|---|---|---|---|---|---|
| 1 | Developer workstation | GitLab | 443 / 22 | Push code | ✅ |
| 2 | Runner | GitLab | 443 | Fetch jobs, clone source, **push the prod tag-bump** (`CI_JOB_TOKEN`) | ✅ |
| 3 | Runner | `gcr.io`, `registry.access.redhat.com` | 443 | Pull the **Kaniko** image + `ubi9` (promote job) | ✅ |
| 4 | Runner | JFrog | 443 | Kaniko **pushes the image** | ✅ |
| 5 | Cluster (ArgoCD) | GitLab | 443 | Clone the repo **and list branches (API)** for the generator | ✅ |
| 6 | Cluster nodes | JFrog | 443 | **Pull images** to run pods (`jfrog-pull` secret) | ✅ |
| 7 | Cluster | `registry.redhat.io` / your mirror | 443 | Pull the GitOps operator + ArgoCD images (install only) | ✅ |
| 8 | GitLab | ArgoCD route | 443 | Webhook → instant sync | ⚠️ optional |
| 9 | Admin / developer | OpenShift API `:6443` + ArgoCD route `:443` | — | `oc` access + click **Sync** for prod | ✅ |

**Three things that decide the matrix:**

1. **Where the Runner lives.** SaaS shared runners reach JFrog from the public
   internet — a private JFrog forces a **self-hosted runner**.
2. **`gcr.io` reachability (leg 3).** Kaniko's image lives on `gcr.io`. If that's
   blocked, mirror it into JFrog and change the `image:` in the pipeline.
3. **TLS / proxy.** A public GitLab cert needs no custom CA (drop
   `GIT_SSL_NO_VERIFY`). Private JFrog CA → trust it on the runner and cluster
   nodes. Behind a proxy, set `HTTP(S)_PROXY` on the runner and the cluster Proxy.

---

## 4 · Set your variables

```bash
# --- OpenShift ---
export APPS_DOMAIN="apps.ocp.company.com"          # oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'

# --- GitLab ---
export GITLAB_HOST="gitlab.com"
export GITLAB_GROUP="globetelecom/platforms/…/Applications"   # full nested path
export GITLAB_PROJECT="sample-app"
export GITLAB_DEPLOY_USER="argocd-reader"
export GITLAB_DEPLOY_TOKEN="<read_repository deploy token>"   # A2 — ArgoCD clone
export GITLAB_SCM_TOKEN="<read_api token>"                    # A3 — branch generator

# --- JFrog ---
export JFROG_URL="artifactory.company.com"         # host only
export JFROG_REPO="docker-local"
export JFROG_PULL_USER="svc-cluster-pull"
export JFROG_PULL_TOKEN="<read-only jfrog token>"
export IMAGE_REPO="${JFROG_URL}/${JFROG_REPO}/sample-app"
```

> **Nested subgroups:** `GITLAB_GROUP` may be a full nested path. The repo URL is
> `${GITLAB_HOST}/${GITLAB_GROUP}/${GITLAB_PROJECT}.git`, and GitLab's
> `CI_PROJECT_PATH` resolves the nesting automatically — no pipeline edits needed.

---

## 5 · Part A — Foundation: seed the repository

**Goal:** a seeded project and the two read-only tokens ArgoCD needs. No CI
configuration yet (Part C); no long-lived branch (previews are per feature branch).

### A1 · Seed the project from the reference templates

```bash
git clone https://${GITLAB_HOST}/${GITLAB_GROUP}/${GITLAB_PROJECT}.git
cp -r <reference-repo>/templates/sample-app/. ${GITLAB_PROJECT}/
cd ${GITLAB_PROJECT}

# Use the PREVIEW pipeline as the project's .gitlab-ci.yml
cp .gitlab-ci.preview.yml .gitlab-ci.yml
rm -f .gitlab-ci.preview.yml

# Point the image at YOUR JFrog in both overlays
sed -i "s|__IMAGE_REPO__|${IMAGE_REPO}|g" \
    gitops/overlays/dev/kustomization.yaml \
    gitops/overlays/prod/kustomization.yaml

git add -A && git commit -m "seed: sample-app monorepo (preview model)" && git push -u origin main
```

There is **no `dev` branch** in this model — feature branches are the dev
environments, created on demand. The seeded layout:

```
app/                      application source + Dockerfile
gitops/base/              Deployment, Service, Route (the preview ApplicationSet renders this)
gitops/overlays/prod/     prod overlay; bumped on `main` by promote-prod; manual-sync
.gitlab-ci.yml            any branch: Kaniko build → JFrog (full + short SHA)
                          main (on merge): promote tested image → overlays/prod
```

### A2 · Create the read-only deploy token (ArgoCD clone)

Project → **Settings → Repository → Deploy tokens**. Name `argocd-reader`,
**Username** `argocd-reader` (so it matches `GITLAB_DEPLOY_USER`), scope
`read_repository`. Copy the value into `GITLAB_DEPLOY_TOKEN`. This is the
credential ArgoCD (and every generated preview Application) uses to clone.

### A3 · Create the read-only API token (branch generator)

The branch generator lists branches via the GitLab API, which a deploy token
can't do. Create a **Project (or Group) Access Token**: role `Reporter`, scope
`read_api`. Copy the value into `GITLAB_SCM_TOKEN`.

---

## 6 · Part B — CD: OpenShift + Argo CD

**Goal:** ArgoCD watching the repo, the preview ApplicationSet and the prod
Application registered. Stands alone — does not depend on CI existing yet.

### B1 · Install the OpenShift GitOps operator

```bash
oc apply -f <reference-repo>/deploy/argocd/01-operator-subscription.yaml
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=300s
```

> **OpenShift 4.12:** set the Subscription `channel` to `gitops-1.8`/`gitops-1.9`
> first. Skip entirely if you already run ArgoCD.

### B2 · Create the two namespaces

```bash
for ns in sample-app-dev sample-app-prod; do
  oc create namespace "$ns"
  oc label namespace "$ns" argocd.argoproj.io/managed-by=openshift-gitops
done
```

> **Do both namespaces.** The `managed-by` label (here) *and* the `jfrog-pull`
> secret (next) must exist in **both** `sample-app-dev` and `sample-app-prod`.
> The loops handle both — but applying one at a time and forgetting the second
> surfaces later as `forbidden: … cannot create resource …` on Sync (missing
> label) or `ImagePullBackOff … Authentication is required` (missing secret).

### B3 · Create the JFrog pull secret in each namespace

```bash
for ns in sample-app-dev sample-app-prod; do
  oc create secret docker-registry jfrog-pull -n "$ns" \
    --docker-server="${JFROG_URL}" \
    --docker-username="${JFROG_PULL_USER}" \
    --docker-password="${JFROG_PULL_TOKEN}"
done
```

### B4 · Give ArgoCD read access to the repo (clone)

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

### B5 · Create the branch-generator API token secret

```bash
oc create secret generic gitlab-scm-token -n openshift-gitops \
  --from-literal=token="${GITLAB_SCM_TOKEN}"
```

### B6 · Apply the AppProject, preview ApplicationSet, and prod Application

Edit [`deploy/argocd/sample-app-preview-appset.yaml`](../deploy/argocd/sample-app-preview-appset.yaml):
set the `group` path, `__REPO_URL__`, and `__IMAGE_REPO__`, and confirm the
`branchMatch` regex fits your branch naming (it must **not** match `main`).
Apply the **AppProject first** (the apps reference it):

```bash
oc apply -f <reference-repo>/deploy/argocd/sample-app-project.yaml          # AppProject + prod sync window
oc apply -f <reference-repo>/deploy/argocd/sample-app-preview-appset.yaml   # dev previews
oc apply -f <reference-repo>/deploy/argocd/sample-app-prod.yaml             # prod (edit repoURL)
```

- **`sample-app` (AppProject)** — groups the apps and carries the **prod deploy
  window** (scoped to `sample-app-prod` only). See
  [preview-environments.md §7](preview-environments.md#7--scheduled-prod-deployments-sync-window).
- **`sample-app-preview` (ApplicationSet)** — SCM branch generator → one
  auto-synced Application per matching branch, deployed into `sample-app-dev`.
- **`sample-app-prod` (Application)** — tracks `main`, path `gitops/overlays/prod`,
  **auto-sync gated by the sync window**: a promotion deploys automatically at the
  next window (outside it, it queues). Want a hard human gate instead? Remove the
  `automated:` block from `sample-app-prod.yaml` and sync manually (and drop the
  window).

### B7 · Wire the GitLab → ArgoCD webhook (optional, instant sync)

```bash
WEBHOOK_SECRET=$(openssl rand -hex 20)
oc patch secret argocd-secret -n openshift-gitops --type merge \
  -p "{\"stringData\":{\"webhook.gitlab.secret\":\"${WEBHOOK_SECRET}\"}}"
oc rollout restart deploy/openshift-gitops-server -n openshift-gitops
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'
```

Add it in GitLab → **Settings → Webhooks** (URL `https://<argocd-host>/api/webhook`,
**Push events**, the secret). The **same** endpoint drives *both* the prod
Application and the preview **ApplicationSet** (branch create/update/delete), so
one webhook covers everything. Without it, both fall back to their ~2–3 minute
poll. See [preview-environments.md §6](preview-environments.md#6--instant-updates-with-a-webhook-optional)
for verification and details.

> **Expected now:** no previews exist (nothing pushed yet), and prod is empty. The
> first branch push (Part C/D) creates a preview; the first promotion fills prod.

---

## 7 · Part C — CI: the GitLab pipeline

**Goal:** a branch push builds an image the preview ApplicationSet can deploy,
and a merge to `main` promotes the tested image to prod.

### C1 · Set the four CI/CD variables

Project → **Settings → CI/CD → Variables** (mask + protect the token):
`JFROG_URL`, `JFROG_REPO`, `JFROG_USER`, `JFROG_TOKEN`.

### C2 · Allow CI_JOB_TOKEN to push

Project → **Settings → CI/CD → Job token permissions** → allow this project to
push to its own repository (`ci_push_repository_for_job_token_allowed`). Without
it, `promote-prod`'s tag-bump push fails with `403 — not allowed to push code`.
If your group disables this, use a Project Access Token with `write_repository`
instead and swap it into the `git remote set-url` line.

### C3 · Branch protection, approval, merge method, branch cleanup

**Force all `main` changes through an MR (no direct human pushes).** This is the
key governance control — `main` is prod. There's one subtlety: `promote-prod`
itself pushes the tag bump to `main`, so you can't simply block *all* pushes. Use
a dedicated push identity:

1. Create a **Project Access Token** (or bot/service account): role `Maintainer`,
   scope `write_repository`. Store it as a **masked CI variable**
   (e.g. `GITOPS_PUSH_TOKEN`) and change the `git remote set-url` line in
   `promote-prod` to use it instead of `CI_JOB_TOKEN`.
2. Project → **Settings → Repository → Protected branches** → `main`:
   - **Allowed to push and merge:** *No one* (or just that bot user) — blocks
     direct developer pushes.
   - **Allowed to merge:** *Maintainers* (or a reviewer group) — humans land
     changes only via the MR merge button.
3. Add an **MR approval rule** requiring at least one approval to merge into
   `main` — that approval is the prod gate.

With this, developers **cannot** commit to `main` directly; every change arrives
as a reviewed merge commit, and only the bot token (or `CI_JOB_TOKEN` if your
group permits it) pushes the promotion bump.

Project → **Settings → Merge requests**:
- **Merge method = "Merge commit"** — `promote-prod` reads the tested image from
  the merge commit's 2nd parent (`HEAD^2`). Squash/fast-forward have no 2nd
  parent, so such a commit is treated as "not a promotion" and skipped.
- **Enable "Delete source branch by default"** — deleting the branch on merge is
  what tears down its preview environment.

> **Path filter:** `promote-prod` only runs when a merge changes `app/**` or
> `gitops/**` (see its `rules: changes:`), so docs/README/CI-only changes on
> `main` never promote. Combined with the "skip non-merge commit" guard, prod is
> only ever touched by a reviewed merge that changed application or deploy config.

> **Committer identity:** the pipeline commits as `${GITLAB_USER_EMAIL}` to
> satisfy a "verified committer" push rule. Nothing to configure if your GitLab
> doesn't enforce that rule.

### C4 · Confirm the runner and registries

- The runner must reach **`gcr.io`** (Kaniko image — or mirror it into JFrog),
  `registry.access.redhat.com`, JFrog, and GitLab.
- Kaniko needs **no privileged** access — it builds unprivileged, which is why it
  replaces buildah on locked-down Kubernetes runners.

---

## 8 · Part D — Verify end to end

**1 — Preview (dev):**
```bash
git checkout -b feature-100        # any name matching the branchMatch pattern
# edit app/app.py …
git commit -am "feature-100: change" && git push -u origin feature-100
```
Watch: `build-image` (Kaniko) → JFrog `:<sha>`; within ~2 min the ApplicationSet
creates `sample-app-feature-100` and deploys it to `sample-app-dev`. Test at
`https://sample-app-feature-100-sample-app-dev.${APPS_DOMAIN}`. Push more commits
→ the preview re-syncs to the new image.

**2 — Promote to prod:** open an **MR `feature-100` → `main`**, get it approved,
**merge (as a merge commit)**. `promote-prod` reads `HEAD^2` (the tested tip),
writes that tag into `overlays/prod`, and pushes to `main` — no rebuild.
`sample-app-prod` then deploys **automatically at the next sync window** (it shows
OutOfSync / "blocked by sync window" until then). To deploy immediately —
emergency, or if you kept prod on manual sync — force it: **Sync** in the ArgoCD
UI, or `oc patch application sample-app-prod -n openshift-gitops --type=merge -p '{"operation":{"sync":{"revision":"main"}}}'`.

**3 — Cleanup:** deleting `feature-100` (automatic if you enabled it) removes the
preview Application and prunes `sample-app-feature-100` from `sample-app-dev`.

**4 — Rollback:** `git revert` the promotion merge on `main`, Sync prod.

**5 — Self-heal:** `oc scale deploy/sample-app -n sample-app-prod --replicas=9` and
watch ArgoCD revert it.

**6 — Loki:** run a query from [`logql-queries.md`](logql-queries.md).

---

## 9 · Security notes

**Build execution.** This model uses **Kaniko** — unprivileged, daemonless — so
it runs on restricted Kubernetes runners without privileged/buildah. Alternatives
if policy differs: **Shipwright/BuildConfig** (platform builds, runner holds no
privilege) or privileged buildah on a dedicated tainted node pool.

**Secrets.** Route the JFrog pull secret and CI variables through your secrets
manager (Vault / External Secrets) so they rotate without touching configs.

**Least privilege.** ArgoCD's footprint is the two labelled namespaces plus its
own `openshift-gitops` namespace — no cluster-admin. Both GitLab tokens ArgoCD
holds are **read-only** (`read_repository`, `read_api`). CI push-back uses the
built-in, per-pipeline `CI_JOB_TOKEN` (no long-lived credential).

---

## 10 · Uninstall / rollback

```bash
# Preview ApplicationSet (removes all preview Applications + their workloads)
oc delete applicationset sample-app-preview -n openshift-gitops

# Prod Application (removes the prod workloads it manages)
oc delete application sample-app-prod -n openshift-gitops

# ArgoCD secrets
oc delete secret repo-sample-app gitlab-scm-token -n openshift-gitops
oc patch secret argocd-secret -n openshift-gitops --type=json \
  -p '[{"op":"remove","path":"/data/webhook.gitlab.secret"}]' 2>/dev/null || true

# Namespaces (removes pull secrets + any workloads)
oc delete namespace sample-app-dev sample-app-prod

# The OpenShift GitOps operator — only if YOU installed it and nothing else uses it
oc delete -f <reference-repo>/deploy/argocd/01-operator-subscription.yaml
```

On the GitLab side: delete the project, its CI variables, the deploy token, the
API token, and the webhook. On JFrog: delete any pushed `sample-app` image tags.
Nothing persists outside these objects.
