# Preview environments — one per branch, shared `sample-app-dev` namespace

An alternative to the shared "latest push wins" dev model. Each **feature
branch** gets its own live, testable deployment **on push** — but all previews
live in the **single `sample-app-dev` namespace**, distinguished by name
(feature-wise), not by namespace. Merge to `main` still promotes the tested image
to prod.

**Why one namespace:** the two things that must exist for every deployment — the
`argocd.argoproj.io/managed-by` label (RBAC) and the `jfrog-pull` secret — are
provisioned **once** on `sample-app-dev`. No per-branch namespace creation, no
Kyverno/ESO secret propagation, no ephemeral-namespace RBAC. That operational
simplicity is the whole point of this variant.

**Trigger model:** previews are **branch-triggered** — the ApplicationSet's SCM
Provider (branch) generator watches branches matching a pattern, so a preview
appears as soon as you push such a branch (no MR required). An MR is still how
you get to prod, but it is not needed for a preview.

```
push feature-x ─► CI build (Kaniko) ─► image :<sha>        (every push)
     │
     └─ branch matches pattern ─► ApplicationSet (branch generator) ─► Application "sample-app-<branch-slug>"
                          deploys gitops/base into sample-app-dev as:
                            Deployment/sample-app-<branch-slug>
                            Service/sample-app-<branch-slug>
                            Route/sample-app-<branch-slug>  → auto host: sample-app-<branch-slug>-sample-app-dev.apps…
                          image = :<branch head sha>       ← developer tests here
     │
     └─ open MR → main, approve, merge (merge commit) ─► promote-prod ─► overlays/prod ─► prod (manual Sync)
     └─ delete the branch ─► preview Application removed → prune deletes only that branch's objects
```

---

## 1 · How isolation works inside one namespace

Three things are made unique per branch so deployments coexist safely:

| Concern | Mechanism |
|---|---|
| Object names collide | Kustomize `nameSuffix: -<branch-slug>` → `sample-app-<branch-slug>` |
| Services select the wrong pods | Kustomize `commonLabels: {preview.capdv/branch: <branch-slug>}` — flows into **both** the Deployment and Service selectors, so each Service targets only its own pods |
| Route hosts collide | base `route.yaml` sets **no host** → OpenShift auto-generates `sample-app-<branch-slug>-sample-app-dev.apps.<domain>`, unique because the name is unique |
| Argo prunes another branch's objects | Each generated Application tracks only its own resources; `prune: true` deletes just that branch's objects on close/merge |

> **Branch-name length:** the auto-generated Route host is
> `sample-app-<branch-slug>-sample-app-dev`, and each DNS label must be ≤63
> chars — so keep `<branch-slug>` under ~37 characters (i.e. reasonably short
> branch names). GitLab's `branch_slug` already lowercases and hyphenates the
> name; it just needs to not be excessively long.

Nothing else is isolated — previews share the namespace's resource quota,
NetworkPolicies, and the `jfrog-pull` secret. That's acceptable for a dev tier;
set per-Deployment resource limits (the base already does) so one busy preview
can't starve the others.

---

## 2 · The ApplicationSet

See [`deploy/argocd/sample-app-preview-appset.yaml`](../deploy/argocd/sample-app-preview-appset.yaml).
Replace two placeholders before applying (the group path is set directly in the
generator — edit it there too):

| Placeholder | Value |
|---|---|
| `__REPO_URL__` | `https://gitlab.com/globetelecom/…/capdv-cluster-config.git` |
| `__IMAGE_REPO__` | `globe.jfrog.io/ntg-capdv-docker-local/sample-app` |

It uses the **SCM Provider (branch) generator** scoped to the group, filtered to
`capdv-cluster-config` and to branches matching
`^(feature|feat|fix|hotfix|bugfix|chore)[/-].*`. It points at `gitops/base` and
injects everything per-branch via the `kustomize` block, keyed on the generator's
`{{.branchNormalized}}`, `{{.branch}}`, and `{{.sha}}` parameters.

> **The `branchMatch` pattern must NOT match `main`** (main is prod). RE2 has no
> negative lookahead, so the default uses a prefix convention rather than
> "everything except main." Adjust the regex to your team's branch naming.

### GitLab token for the branch generator

ArgoCD needs a **read-only** GitLab token to list branches:

```bash
oc create secret generic gitlab-scm-token -n openshift-gitops \
  --from-literal=token='<gitlab token with read_api scope>'
```

Connectivity: ArgoCD (in cluster) → `gitlab.com:443` — the same egress it
already uses to clone the repo, so nothing new for the network team.

---

## 3 · CI changes vs. the shared-dev model

The complete preview pipeline is shipped as
[`templates/sample-app/.gitlab-ci.preview.yml`](../templates/sample-app/.gitlab-ci.preview.yml) —
copy its contents into the project's `.gitlab-ci.yml`. (The default
`.gitlab-ci.yml` is the shared-dev variant used by the demo `install.sh`.) The
two jobs are shown below for reference. There is **no `deploy-dev` job** in this
model — the ApplicationSet injects the image, so CI never writes a tag back for
dev/preview.

### build-image — build on every branch push, tag with the FULL SHA

The ApplicationSet deploys `:{{.sha}}` (the full 40-char branch head SHA), so the
image for **every** commit on a branch must exist. Build on every non-`main` push
and push both the full and short SHA tags:

```yaml
build-image:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  rules:
    - if: '$CI_COMMIT_BRANCH != "main"'      # every push on any feature branch
  script:
    - 'echo "Building ${IMAGE} from ${CI_COMMIT_REF_NAME} @ ${CI_COMMIT_SHA}"'
    - 'AUTH=$(printf "%s:%s" "${JFROG_USER}" "${JFROG_TOKEN}" | base64 | tr -d "\n")'
    - 'mkdir -p /kaniko/.docker'
    - 'printf "{\"auths\":{\"%s\":{\"auth\":\"%s\"}}}" "${JFROG_URL}" "${AUTH}" > /kaniko/.docker/config.json'
    - '/kaniko/executor --context "${CI_PROJECT_DIR}/app" --dockerfile "${CI_PROJECT_DIR}/app/Dockerfile" --destination "${IMAGE}:${CI_COMMIT_SHA}" --destination "${IMAGE}:${CI_COMMIT_SHORT_SHA}" --build-arg APP_VERSION="${CI_COMMIT_SHORT_SHA}"'
```

### promote-prod — promote the TESTED image via the merge commit's 2nd parent

On merge to `main`, the exact image the reviewer tested is the **MR source
branch tip** — which is the merge commit's second parent (`HEAD^2`). No rebuild:

```yaml
promote-prod:
  stage: promote-prod
  image: registry.access.redhat.com/ubi9/ubi:latest
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - 'dnf install -y git >/dev/null'
    - 'SRC_SHA=$(git rev-parse HEAD^2 2>/dev/null || echo "")'
    - 'test -n "${SRC_SHA}" || { echo "No merge-commit 2nd parent. Use the *Merge commit* method (not squash / fast-forward) so prod can promote the tested image."; exit 1; }'
    - 'echo "Promoting tested image ${SRC_SHA} to prod"'
    - 'sed -i -E "s|(newTag:)[[:space:]]*\"[^\"]*\"|\1 \"${SRC_SHA}\"|" gitops/overlays/prod/kustomization.yaml'
    - 'git config user.email "${GITLAB_USER_EMAIL}"'   # verified-committer push rule
    - 'git config user.name  "${GITLAB_USER_NAME}"'
    - 'git remote set-url origin "https://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"'
    - 'git add gitops/overlays/prod/kustomization.yaml'
    - 'git diff --cached --quiet && echo "prod already at ${SRC_SHA}" && exit 0 || true'
    - 'git commit -m "prod: promote ${SRC_SHA} [skip ci]"'
    - 'git push origin HEAD:main'
```

> **Merge strategy matters.** This promotes `HEAD^2`, which only exists for a
> **Merge commit**. Squash and fast-forward merges collapse history and have no
> second parent — set the project's merge method to **Merge commit** (Settings →
> Merge requests). This also gives you the merge commit as an audit record.

The prod side is otherwise unchanged: `sample-app-prod` Application tracks
`main`, path `gitops/overlays/prod`, **manual Sync** (the deliberate gate).

---

## 4 · Lifecycle

| Event | Result |
|---|---|
| Push a matching branch | Branch generator creates `sample-app-<branch-slug>`; preview deploys to `sample-app-dev`; URL is `https://sample-app-<branch-slug>-sample-app-dev.apps.<domain>` |
| Push more commits | New build → new head SHA → ApplicationSet re-reads the branch and re-syncs the preview to the new image |
| Open an MR → `main`, approve, merge (merge commit) | `promote-prod` copies the tested image into prod (the MR is the prod gate, not the preview trigger) |
| **Delete the branch** | Preview Application removed → prune deletes only that branch's objects |

---

## 5 · Prerequisites recap (all one-time)

1. `sample-app-dev` namespace: `argocd.argoproj.io/managed-by=openshift-gitops`
   label **and** `jfrog-pull` secret — already in place.
2. `gitlab-scm-token` secret in `openshift-gitops` (read-only GitLab token, `read_api`).
3. CI variables `JFROG_URL/REPO/USER/TOKEN`, `ci_push_repository_for_job_token_allowed=true`,
   protected `main` with approval, merge method = **Merge commit**.
4. Apply the ApplicationSet; retire the old single dev Application + the
   `deploy-dev` CI job.
5. **Enable "Delete source branch" on merge** (Settings → Merge requests) — or
   delete branches manually. Previews are torn down when the branch is deleted,
   so leaving merged branches around leaves their previews running.

**Re-sync timing:** by default there are two poll clocks — the branch generator
(`requeueAfterSeconds`, 120s in the manifest) and ArgoCD's Application reconcile
(180s). A commit therefore appears in its preview within ~2–3 min. To make it
near-instant, wire the webhook in [Section 6](#6--instant-updates-with-a-webhook-optional).

```bash
# Check the two intervals:
oc get applicationset sample-app-preview -n openshift-gitops \
  -o jsonpath='{.spec.generators[0].scmProvider.requeueAfterSeconds}{"\n"}'      # → 120
oc get cm argocd-cm -n openshift-gitops -o jsonpath='{.data.timeout\.reconciliation}{"\n"}'  # empty = 180s default
```

---

## 6 · Instant updates with a webhook (optional)

Polling is the fallback. A **single GitLab webhook** makes both the preview
ApplicationSet and the prod Application react in seconds. Importantly, both the
**Application** and **ApplicationSet** webhooks are handled by the **same**
ArgoCD server endpoint — `/api/webhook` — so you configure just one webhook (the
same one from Part B7 of the runbook).

### 6.1 · Ensure the shared secret exists

```bash
# Should print a value; if empty, set it and restart argocd-server:
oc get secret argocd-secret -n openshift-gitops \
  -o jsonpath='{.data.webhook\.gitlab\.secret}' | base64 -d; echo

# (only if empty)
WEBHOOK_SECRET=$(openssl rand -hex 20)
oc patch secret argocd-secret -n openshift-gitops --type merge \
  -p "{\"stringData\":{\"webhook.gitlab.secret\":\"${WEBHOOK_SECRET}\"}}"
oc rollout restart deploy/openshift-gitops-server -n openshift-gitops
echo "secret: ${WEBHOOK_SECRET}"
```

### 6.2 · Get the ArgoCD server host

```bash
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}'
```

### 6.3 · Add the webhook in GitLab

Project → **Settings → Webhooks → Add new webhook**:

- **URL:** `https://<argocd-host>/api/webhook`
- **Secret token:** the `webhook.gitlab.secret` value from 6.1
- **Trigger — Push events:** ✅ (this is the key one — branch create/update/delete
  all fire push events, which is exactly what the SCM branch generator needs)
- **Trigger — Merge request events:** ✅ (harmless here; needed only if you switch
  to the PR generator)
- **SSL verification:** enable if the ArgoCD route cert is trusted; otherwise off.

### 6.4 · Verify it fires

```bash
# Watch the ApplicationSet controller receive the webhook on your next push:
oc logs -n openshift-gitops deploy/openshift-gitops-applicationset-controller -f | grep -i webhook
```

Push a commit (or create/delete a branch) and you should see the controller
regenerate immediately instead of waiting for the 120s poll. GitLab's webhook
page (**Edit → Recent events**) also shows the delivery + response code.

### Notes & fallbacks

- **Reachability:** GitLab must reach the ArgoCD route (connectivity leg 8). A
  public GitLab (gitlab.com) needs the route publicly reachable; if it isn't, the
  webhook simply won't deliver and the 120s/180s polls still cover you.
- **Older GitOps/ArgoCD:** if the ApplicationSet controller doesn't react to the
  server webhook, lower `requeueAfterSeconds` (e.g. `30`) as a simpler speed-up.
- The webhook is an **optimization, not a requirement** — the model is fully
  correct on polling alone.

---

## 7 · When to graduate to namespace-per-branch

Move to a namespace per preview only if you need **hard isolation** (separate
NetworkPolicies/secrets per feature), **independent resource quotas**, or
**per-tenant RBAC**. That reintroduces per-namespace provisioning (label +
pull secret) — solve it with a Kyverno `generate` policy or External Secrets.
For a single team's dev tier, the shared-namespace model here is simpler and
sufficient.
