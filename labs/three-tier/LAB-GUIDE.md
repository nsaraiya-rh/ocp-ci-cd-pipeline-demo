# Hands-on Lab — GitOps CI/CD end to end (three-tier app)

A guided lab for **6 users** to learn the full delivery cycle on the GitOps
pipeline you've built: **push an app to Git → configure it in GitLab → deploy to
your own dev environment → open an MR → promote to prod.**

The app is the **three-tier web stack** (frontend + api + MySQL + adminer, with
zero-trust NetworkPolicies). The **frontend is built by CI** (GitLab + Kaniko →
JFrog) and deployed by **Argo CD**; the api / mysql / adminer tiers use public
images. So this lab covers the **full CI + CD** cycle.

## The model

- Each user gets **their own dev namespace** and a **long-lived branch**.
- You edit the **frontend source** → **CI builds an image** → the built tag is
  written to your branch → **Argo CD deploys it to your dev namespace**.
- Merging your branch to **`main`** (via a reviewed MR) **promotes the tested
  image** to the **shared prod namespace**.

```
you edit app/frontend + push feature/userN
        │
   CI: Kaniko build ─► JFrog :<sha> ─► deploy-dev writes tag to your branch
        │
   Argo CD (three-tier-dev-userN) ─► namespace three-tier-userN   (your dev, test your URL)
        │
open MR feature/userN → main ─► approve ─► merge ─► promote-prod copies the tested tag
        │
   Argo CD (three-tier-prod) ─► namespace three-tier-prod   (shared prod)
```

| | Who | Isolation |
|---|---|---|
| **Dev** | each user | your branch → your namespace (fully parallel) |
| **Prod** | shared | one `main`, one prod namespace (promote one at a time) |

---

## Prerequisites — tools & access

### On your workstation (every user)

| Tool | Why | Check |
|---|---|---|
| **`oc`** (OpenShift CLI) | inspect your namespace, rollout status, exec, get routes | `oc version` |
| **`git`** | clone, branch, commit, push | `git --version` |
| **A web browser** | open your app/Adminer URLs; use GitLab (open + approve MRs) | — |

> `oc` version should match the cluster's major.minor (4.x). Download it from the
> OpenShift web console (**?** menu → *Command line tools*).

### Access & accounts (every user)

- **OpenShift login** — you must be logged in to the cluster with rights in your
  namespace (`three-tier-userN`). Get a login command from the web console
  (top-right → *Copy login command*) and run it:
  ```bash
  oc login --token=sha256~... --server=https://api.<cluster>:6443
  oc whoami          # confirm you're logged in
  ```
- **GitLab account** with **Developer** access to the lab project (push branches,
  open MRs). At least one reviewer per pair needs **rights to approve** MRs.
- **Git push credentials for GitLab** — either an **SSH key** added to your GitLab
  account, or an **HTTPS Personal Access Token** (`write_repository`). Test:
  ```bash
  git ls-remote <LAB_REPO_URL>     # should list refs, not prompt-fail
  ```
- **Network reachability** — your workstation needs to reach the cluster API
  (`:6443`), the app Routes (`:443`), and GitLab (`:443`/`:22`).

### Instructor also needs (for Part 0)

| Tool | Why |
|---|---|
| **`oc`** with rights to create namespaces + apply in `openshift-gitops` | create the 6 + 1 namespaces, labels, secrets; apply the Argo CD manifests |
| **`git`** | seed the lab GitLab repo, create the user branches |
| **`openssl`** | generate the MySQL passwords in step 0.3 |
| **GitLab Maintainer/Owner** | create the lab project, set an MR approval rule |

### Cluster / CI prerequisites (instructor confirms once)

- **OpenShift 4.x** with the **OpenShift GitOps (Argo CD) operator** installed.
- A **default StorageClass** for the MySQL PVC — `oc get storageclass`.
- **A GitLab runner** for the lab project that can build with Kaniko — egress to
  **`gcr.io`** (Kaniko image), **`registry.access.redhat.com`**, **JFrog**, and GitLab.
- **JFrog** — a Docker repo the CI can push the frontend image to, plus the CI
  push token (see Part 0.6).
- Cluster egress to pull images: **`docker.io`** (node, adminer), **`registry.redhat.io`**
  (MySQL), and **JFrog** (the built frontend), with the cluster's Red Hat pull
  secret in place (present by default on OpenShift).

> You do **not** need `kustomize`, `helm`, or `docker` **locally** — CI (Kaniko)
> builds the frontend image on the runner, and Argo CD renders Kustomize on the
> cluster. You only edit source/YAML and push with `git`.

---

# Part 0 — Instructor setup (one-time)

> Do this **once** before the session. Users start at Part 1.

### 0.1 · Create the GitLab lab project and seed it

Create an empty GitLab project (e.g. `platform/three-tier-lab`) and push the
**contents of this `labs/three-tier/` directory** to it so the repo root has
`gitops/`, `argocd/`, and this guide:

```bash
export LAB_REPO_URL="https://gitlab.com/globetelecom/platforms/ntg-redhat-capability-development-program/Applications/three-tier-lab.git"

git clone ${LAB_REPO_URL} && cd three-tier-lab
cp -r <this-repo>/labs/three-tier/. .
git add -A && git commit -m "seed: three-tier lab" && git push -u origin main
```

The Argo manifests in `argocd/` are **already pre-filled** with this repo URL,
so step 0.5's `sed` is a no-op — apply them as-is.

### 0.2 · Check the cluster has a default StorageClass

MySQL needs a PVC. `mysql.yaml` omits `storageClassName` (uses the default):

```bash
oc get storageclass          # one should be marked (default)
```
If none is default, set `storageClassName:` in `gitops/base/mysql.yaml` to a real class.

### 0.3 · Create the 6 dev namespaces + the prod namespace (label + DB secret)

```bash
for u in user1 user2 user3 user4 user5 user6 prod; do
  ns="three-tier-$u"
  oc create namespace "$ns" 2>/dev/null || true
  oc label namespace "$ns" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
  oc create secret generic mysql-credentials -n "$ns" \
    --from-literal=database=appdb \
    --from-literal=username=appuser \
    --from-literal=password="$(openssl rand -hex 12)" \
    --from-literal=root-password="$(openssl rand -hex 16)" 2>/dev/null || true
done
```

- The **label** is what lets Argo CD deploy into the namespace.
- The **`mysql-credentials`** secret is created out-of-band (not in Git), one per namespace.

### 0.4 · Create the 6 user branches

Each user's dev Application tracks a long-lived branch. Names follow the same
branch convention as the sample-app pipeline
(`^(feature|feat|fix|hotfix|bugfix|chore)[/-].*`), so `feature/userN` conforms:

```bash
for u in user1 user2 user3 user4 user5 user6; do
  git push origin main:refs/heads/feature/$u
done
```

> The three-tier lab uses a **list generator** (per-user namespace), so the
> `branchMatch` regex isn't applied as a filter here — the branch *names* just
> follow the convention for consistency. (The sample-app preview pipeline is the
> one that actually enforces `branchMatch` via its SCM branch generator.)

### 0.5 · Wire Argo CD

The manifests in `argocd/` are **pre-filled with the repo URL**, so just apply
them — **project first**:

```bash
oc apply -f argocd/three-tier-project.yaml       # AppProject (project first)
oc apply -f argocd/three-tier-dev-appset.yaml    # 6 per-user dev Applications
oc apply -f argocd/three-tier-prod.yaml          # shared prod Application
```

> Seeded an older copy that still has `__LAB_REPO_URL__`? Replace it first.
> On **macOS** use the empty backup arg (`-i ''`):
> `sed -i '' "s|__LAB_REPO_URL__|${LAB_REPO_URL}|g" argocd/*.yaml`
> (Linux/GNU sed: drop the `''`.)

### 0.6 · Configure CI on the lab project (for the frontend build)

The frontend is built by CI, so the lab GitLab project needs:

1. **CI/CD variables** (Settings → CI/CD → Variables):
   | Key | Value | Masked | When |
   |---|---|---|---|
   | `JFROG_URL` | `globe.jfrog.io` | no | always |
   | `JFROG_REPO` | `ntg-capdv-docker-local` | no | always |
   | `JFROG_USER` | your CI push user | no | always |
   | `JFROG_TOKEN` | your CI push token | **yes** | always |
   | `GITOPS_PUSH_TOKEN` | Project Access Token, `write_repository` (step 2b) | **yes** | strict `main` |
   | `GIT_BOT_EMAIL` | the bot's `project_<id>_bot_<hash>@noreply.gitlab.com` | no | strict `main` + verified-committer rule |

   > `JFROG_URL`/`JFROG_REPO` **must match** the `newName` in
   > `gitops/overlays/{dev,prod}/kustomization.yaml`
   > (`${JFROG_URL}/${JFROG_REPO}/three-tier-frontend`).
   >
   > **GitLab enforcing "reject unverified users"?** Then `GIT_BOT_EMAIL` is
   > **required** with `GITOPS_PUSH_TOKEN` (the bot's commit must carry a verified
   > email). Find the bot's username under **Project → Members** and append
   > `@noreply.gitlab.com`.

2. **Push-back — pick one:**

   **(a) Simple — `CI_JOB_TOKEN`:** Settings → CI/CD → Job token permissions →
   check **"Allow Git push requests to the repository"**. `deploy-dev`/`promote-prod`
   then push as the triggering user. (Whoever merges to `main` must have push
   rights on `main` — easiest if the instructor merges.)

   **(b) Strict — `GITOPS_PUSH_TOKEN` bot (MR-only `main`):**
   - Create a **Project Access Token** (Settings → Access Tokens): role
     **Maintainer**, scope **`write_repository`**; copy the value (shown once).
   - Add it as a masked CI variable **`GITOPS_PUSH_TOKEN`**.
   - **Protected branches → `main`** → *Allowed to push and merge* → add the
     token's **bot user** (`project_<id>_bot_…`); set humans to *No one* (push),
     *Maintainers* (merge).
   - **If your GitLab enforces "reject unverified users"** (committer email must
     be verified): the bot push fails unless the committer is the bot's email.
     Set CI variable **`GIT_BOT_EMAIL`** = the bot's `@noreply` email (from
     Project → Members) — the pipeline uses it when set.

3. **Runner** — a GitLab runner that can reach **`gcr.io`** (the Kaniko image),
   `registry.access.redhat.com`, JFrog, and GitLab.

### 0.7 · Confirm

```bash
oc get applications -n openshift-gitops | grep three-tier
# three-tier-dev-user1 … user6  → Synced/Healthy into their namespaces
# three-tier-prod               → Synced/Healthy into three-tier-prod
```

The frontend pods start on `:initial` (no build yet) and go green once the first
build runs. Hand each user their **username** (`user1`…`user6`) and the
**`LAB_REPO_URL`**.

---

# Part 1 — Get your bearings (each user)

Set your identity once per shell:

```bash
export U=user1                 # ← YOUR username
export NS=three-tier-$U        # your dev namespace
export LAB_REPO_URL="https://gitlab.com/globetelecom/platforms/ntg-redhat-capability-development-program/Applications/three-tier-lab.git"
```

Look at what's already running for you:

```bash
oc get pods,route -n $NS
```

You'll see `api`, `mysql-0`, and `adminer` **Running**, and the `frontend` pod in
**ImagePullBackOff** — that's expected: the frontend image doesn't exist yet
(tag `:initial`). **You'll build it in Part 2**, and it'll come alive. Your
frontend Route is already created:

```bash
echo "https://$(oc get route frontend -n $NS -o jsonpath='{.spec.host}')"
```

(It won't serve until your first build — that's the point of Part 2.)

---

# Part 2 — Change the source → CI builds → deploy to *your* dev

Clone the lab repo and switch to **your** branch:

```bash
git clone ${LAB_REPO_URL} three-tier-lab && cd three-tier-lab
git checkout feature/$U
```

Edit the frontend **source** — the `<h1>` in **`app/frontend/index.html`** — to
include your name, e.g.:

```html
<h1>Hello from user1 — my first CI/CD build!</h1>
```

Commit and push to **your** branch:

```bash
git commit -am "$U: change frontend message"
git push origin feature/$U
```

**Watch the CI pipeline** (Build → Pipelines in GitLab, or the CLI): `build-image`
(Kaniko) builds your frontend image and pushes it to JFrog `:<sha>`; then
`deploy-dev` writes that tag into `gitops/overlays/dev` on **your** branch and
pushes a `[skip ci]` commit.

Now **Argo CD** deploys the built image to **your** namespace (~1–2 min):

```bash
oc get application three-tier-dev-$U -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
oc rollout status deploy/frontend -n $NS
oc get deploy frontend -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # → …/three-tier-frontend:<sha>
```

Reload your frontend URL — **your message is live**, served by an image *you
just built*. Full CI + CD: source → CI build → Git → Argo CD → your namespace.
No one else's environment changed.

---

# Part 3 — Open a Merge Request (promote toward prod)

In GitLab, open an MR from **`feature/$U` → `main`**:

- **Merge requests → New merge request**, source `feature/userN`, target `main`, Create.
- Assign a **peer** as reviewer.

Your reviewer opens the MR, looks at the diff (your ConfigMap change), and
**Approves**. (Approval is the quality gate — it does not deploy anything yet.)

> **Prod is shared.** Coordinate so users merge **one at a time**. If someone
> merged before you and you edited the same line, GitLab will show a conflict —
> rebase your branch on the latest `main` and resolve it (a real-world skill):
> ```bash
> git fetch origin && git rebase origin/main   # resolve conflicts, then:
> git push -f origin feature/$U
> ```

---

# Part 4 — Merge → prod deploys automatically

When it's your turn, **Merge** the MR (as a merge commit). That puts your change
on `main`, and the **`three-tier-prod`** Argo CD Application deploys it to the
shared prod namespace:

```bash
oc get application three-tier-prod -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status} rev={.status.sync.revision}{"\n"}'
oc rollout status deploy/frontend -n three-tier-prod
echo "https://$(oc get route frontend -n three-tier-prod -o jsonpath='{.spec.host}')"
```

Open the **prod** URL — your merged message is now live in prod. **That's the
full cycle:** code in Git → your dev env → reviewed MR → prod.

---

# Part 5 — Explore what you deployed (optional)

**The tiers talk to each other, but only as allowed** (NetworkPolicies):

```bash
# frontend → api is allowed; frontend → mysql is BLOCKED (deny-all + explicit allows)
oc exec deploy/frontend -n $NS -- sh -c 'wget -qO- --timeout=3 http://api:3000/ ; echo'      # ok
oc exec deploy/frontend -n $NS -- sh -c 'nc -z -w3 mysql 3306; echo rc=$?'                     # blocked
```

**Browse the database** via Adminer (only api/adminer may reach MySQL):

```bash
echo "https://$(oc get route adminer -n $NS -o jsonpath='{.spec.host}')"
# System: MySQL · Server: mysql · DB: appdb
# user/pass: oc get secret mysql-credentials -n $NS -o jsonpath='{.data.username}' | base64 -d ; echo
```

**Autoscaling** — the api has an HPA (2→6 on 70% CPU):

```bash
oc get hpa api-hpa -n $NS
```

---

# Cleanup

Delete your branch when done (this does not touch prod):
```bash
git push origin --delete feature/$U
```
Instructor teardown:
```bash
oc delete applicationset three-tier-dev -n openshift-gitops
oc delete application three-tier-prod -n openshift-gitops
oc delete appproject three-tier-lab -n openshift-gitops
oc delete namespace three-tier-user1 three-tier-user2 three-tier-user3 \
                    three-tier-user4 three-tier-user5 three-tier-user6 three-tier-prod
```

---

# Appendix A — What was intentionally left out (and why)

The original manifests included cluster-infra pieces that don't fit a per-user
GitOps lab. They're **not** in `gitops/base`; add them deliberately if needed:

| Component | Why excluded | To add |
|---|---|---|
| **EgressFirewall / EgressIP** | Need real CIDRs/egress IPs; cluster-network scope | Set your ranges, add to a prod-only overlay |
| **DaemonSet (log-agent)** | One pod per node × per namespace, `hostPath`, elevated SCC | Deploy once cluster-wide, not per user |
| **frontend BuildConfig / ImageStream** | Lab builds the frontend with **Kaniko** (`.gitlab-ci.yml`) instead | Use the OpenShift BuildConfig if you prefer in-cluster S2I builds |
| **api CI build** | Only the frontend is built; api uses a public stub image | Give `app/api/` a Dockerfile + a build/deploy-dev job like the frontend |
| **CronJob / migration Job** | DB-dependent stubs, add noise | Include once you have a real api image |
| **ACS vuln demo** (`09-...`) | Separate from the app — for ACS scanning only | `oc apply -f` it directly when demoing ACS |

# Appendix B — Troubleshooting

| Symptom | Fix |
|---|---|
| Dev app `ComparisonError: … project three-tier-lab does not exist` | Apply `three-tier-project.yaml` first |
| Pods `CreateContainerConfigError` on secret | `mysql-credentials` missing in that namespace — re-run 0.3 for it |
| `mysql-0` Pending | No default StorageClass — set `storageClassName` in `mysql.yaml` (0.2) |
| Argo can't deploy to a namespace (`forbidden`) | Namespace missing the `argocd.argoproj.io/managed-by=openshift-gitops` label (0.3) |
| Frontend route 503 | frontend pod not Ready yet, or the `allow-router-to-frontend` NetworkPolicy didn't apply — `oc get netpol -n $NS` |
| Your change didn't appear in dev | Confirm you pushed to `feature/$U` (not `main`), and the dev app targetRevision is `feature/$U` |
