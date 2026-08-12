# Hands-on Lab — GitOps CI/CD end to end (three-tier app)

A guided lab for **6 users** to learn the full delivery cycle on the GitOps
pipeline you've built: **push an app to Git → configure it in GitLab → deploy to
your own dev environment → open an MR → promote to prod.**

The app is the **three-tier web stack** (frontend + api + MySQL + adminer, with
zero-trust NetworkPolicies), deployed by **Argo CD** — no manual `oc apply`.

## The model

- Each user gets **their own dev namespace** and a **long-lived branch**.
  Pushing to your branch updates *your* dev environment only.
- Merging your branch to **`main`** (via a reviewed MR) promotes to the **shared
  prod namespace**.

```
you push to  lab/userN   ─► Argo CD (three-tier-dev-userN) ─► namespace three-tier-userN   (your dev)
                                                                   │ test at your own URL
open MR  lab/userN → main ─► peer approves ─► merge ─► Argo CD (three-tier-prod) ─► namespace three-tier-prod (shared)
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

### Cluster prerequisites (instructor confirms once)

- **OpenShift 4.x** with the **OpenShift GitOps (Argo CD) operator** installed.
- A **default StorageClass** for the MySQL PVC — `oc get storageclass`.
- Cluster egress to pull images: **`docker.io`** (nginx, node, adminer) and
  **`registry.redhat.io`** (MySQL), with the cluster's Red Hat pull secret in
  place (present by default on OpenShift).

> You do **not** need `kustomize`, `helm`, or `docker` locally — Argo CD renders
> Kustomize on the cluster, and the lab uses pre-built public images (no image
> build). You only edit YAML and push with `git`.

---

# Part 0 — Instructor setup (one-time)

> Do this **once** before the session. Users start at Part 1.

### 0.1 · Create the GitLab lab project and seed it

Create an empty GitLab project (e.g. `platform/three-tier-lab`) and push the
**contents of this `labs/three-tier/` directory** to it so the repo root has
`gitops/`, `argocd/`, and this guide:

```bash
git clone https://gitlab.com/<group>/three-tier-lab.git && cd three-tier-lab
cp -r <this-repo>/labs/three-tier/. .
git add -A && git commit -m "seed: three-tier lab" && git push -u origin main
```

Note the repo URL — call it **`LAB_REPO_URL`** below.

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

Each user's dev Application tracks a long-lived branch:

```bash
for u in user1 user2 user3 user4 user5 user6; do
  git push origin main:refs/heads/lab/$u
done
```

### 0.5 · Wire Argo CD

Set the repo URL in the three Argo manifests, then apply them:

```bash
sed -i "s|__LAB_REPO_URL__|${LAB_REPO_URL}|g" argocd/*.yaml

oc apply -f argocd/three-tier-project.yaml       # AppProject (project first)
oc apply -f argocd/three-tier-dev-appset.yaml    # 6 per-user dev Applications
oc apply -f argocd/three-tier-prod.yaml          # shared prod Application
```

### 0.6 · Confirm

```bash
oc get applications -n openshift-gitops | grep three-tier
# three-tier-dev-user1 … user6  → Synced/Healthy into their namespaces
# three-tier-prod               → Synced/Healthy into three-tier-prod
```

Hand each user their **username** (`user1`…`user6`) and the **`LAB_REPO_URL`**.

---

# Part 1 — Get your bearings (each user)

Set your identity once per shell:

```bash
export U=user1                 # ← YOUR username
export NS=three-tier-$U        # your dev namespace
```

Look at what's already running for you:

```bash
oc get pods,route -n $NS
```

You should see `frontend`, `api`, `mysql-0`, `adminer` pods, and two Routes.
Open your **frontend** URL:

```bash
echo "https://$(oc get route frontend -n $NS -o jsonpath='{.spec.host}')"
```

It shows the default "Three-Tier Lab — edit me!" page. That page is what you'll change.

---

# Part 2 — Make a change and deploy it to *your* dev

Clone the lab repo and switch to **your** branch:

```bash
git clone ${LAB_REPO_URL} three-tier-lab && cd three-tier-lab
git checkout lab/$U
```

Edit the page text in **`gitops/base/frontend.yaml`** — change the `<h1>` inside
the `frontend-content` ConfigMap to include your name, e.g.:

```yaml
<h1>Hello from user1 — my first GitOps deploy!</h1>
```

Commit and push to **your** branch:

```bash
git commit -am "$U: change frontend message"
git push origin lab/$U
```

Now watch Argo CD deploy it to **your** namespace (auto-syncs within ~1–2 min):

```bash
oc get application three-tier-dev-$U -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
oc rollout status deploy/frontend -n $NS
```

Reload your frontend URL — **your message is live.** You just did a GitOps
deploy: Git is the source of truth, Argo CD reconciled your namespace to it.
No one else's environment changed.

---

# Part 3 — Open a Merge Request (promote toward prod)

In GitLab, open an MR from **`lab/$U` → `main`**:

- **Merge requests → New merge request**, source `lab/userN`, target `main`, Create.
- Assign a **peer** as reviewer.

Your reviewer opens the MR, looks at the diff (your ConfigMap change), and
**Approves**. (Approval is the quality gate — it does not deploy anything yet.)

> **Prod is shared.** Coordinate so users merge **one at a time**. If someone
> merged before you and you edited the same line, GitLab will show a conflict —
> rebase your branch on the latest `main` and resolve it (a real-world skill):
> ```bash
> git fetch origin && git rebase origin/main   # resolve conflicts, then:
> git push -f origin lab/$U
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
git push origin --delete lab/$U
```
Instructor teardown:
```bash
oc delete applicationset three-tier-dev -n openshift-gitops
oc delete application three-tier-prod -n openshift-gitops
oc delete appproject three-tier -n openshift-gitops
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
| **frontend BuildConfig / ImageStream** | Lab uses the public nginx image (no build) | Point it at a real frontend repo; swap the image |
| **CronJob / migration Job** | DB-dependent stubs, add noise | Include once you have a real api image |
| **ACS vuln demo** (`09-...`) | Separate from the app — for ACS scanning only | `oc apply -f` it directly when demoing ACS |

# Appendix B — Troubleshooting

| Symptom | Fix |
|---|---|
| Dev app `ComparisonError: … project three-tier does not exist` | Apply `three-tier-project.yaml` first |
| Pods `CreateContainerConfigError` on secret | `mysql-credentials` missing in that namespace — re-run 0.3 for it |
| `mysql-0` Pending | No default StorageClass — set `storageClassName` in `mysql.yaml` (0.2) |
| Argo can't deploy to a namespace (`forbidden`) | Namespace missing the `argocd.argoproj.io/managed-by=openshift-gitops` label (0.3) |
| Frontend route 503 | frontend pod not Ready yet, or the `allow-router-to-frontend` NetworkPolicy didn't apply — `oc get netpol -n $NS` |
| Your change didn't appear in dev | Confirm you pushed to `lab/$U` (not `main`), and the dev app targetRevision is `lab/$U` |
