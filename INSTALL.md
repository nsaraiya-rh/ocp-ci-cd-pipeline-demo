# Installing on a fresh OpenShift cluster

One command deploys the whole stack: ArgoCD, GitLab, GitLab Runner, the image-push
service account, the GitLab project + CI variables, GitHub secrets, and the ArgoCD
Application.

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift cluster | 4.14+, with cluster-admin. Tested on 4.21. |
| `oc`, `helm`, `git` | on `PATH` |
| `gh` CLI | optional but recommended — used to set the GitHub secret/variable |
| GitHub PAT | **classic** token with **`repo` + `workflow`** scopes |
| Cluster resources | ~8 vCPU / 16Gi free. GitLab bundles PostgreSQL, Redis, MinIO, Gitaly. |

> A fine-grained GitHub token will **not** work unless it grants *Contents: read/write*
> **and** *Workflows: read/write*. A classic PAT is simpler.

## Run it

```bash
oc login --token=sha256~... --server=https://api.<cluster-domain>:6443
export GH_PAT=ghp_xxxxxxxxxxxx
./install.sh
```

The script auto-detects the cluster's apps domain, so **nothing is hardcoded** —
it works on any cluster. Expect **~15–25 minutes**, mostly waiting for GitLab.

It is **idempotent** — safe to re-run if a step fails.

## What it does

| Step | Action |
|---|---|
| 1 | OpenShift GitOps operator → ArgoCD |
| 2 | `sample-app` namespace, `gitlab-pusher` SA (+ `system:image-builder`), long-lived token, imagestream, registry route |
| 3 | `gitlab-system` namespace, custom `gitlab-anyuid` SCC, Helm repo |
| 4 | Self-signed CA + wildcard cert for `*.<apps-domain>` → TLS secrets |
| 5 | GitLab via **Helm** (chart 9.11.8 / GitLab 18.11) exposed via OpenShift Routes |
| 6 | GitLab root PAT (rails console) + instance runner registration |
| 7 | GitLab Runner (Helm 0.76.3), Kubernetes executor, **privileged** SCC for buildah |
| 8 | GitLab project `root/sample-app`, unprotect `main`, CI variables |
| 9 | GitHub `GITLAB_PUSH_TOKEN` secret + `GITLAB_URL` variable, ArgoCD Application, and a GitHub→ArgoCD push webhook |

### ArgoCD sync behaviour

The Application uses `syncPolicy.automated` with `prune` and `selfHeal`, so it
deploys without manual intervention. By default ArgoCD only *notices* new commits
when it polls (`timeout.reconciliation`, 180s), so step 9 also registers a GitHub
push webhook to `https://<argocd-host>/api/webhook` — gitops commits then sync in
seconds instead of up to 3 minutes.

The webhook is created with `insecure_ssl: 1` because the ArgoCD route uses the
cluster's self-signed router certificate. The shared secret is stored in the
`argocd-secret` Secret under `webhook.github.secret` (and in `credentials.txt`).

## Credentials

Everything generated is written to **`.install-output/credentials.txt`** (gitignored,
mode 600): ArgoCD admin password, GitLab root password, GitLab PAT, runner token.

> **Keep this file.** The GitLab root password and PATs cannot be recovered later —
> the same way a lost `kubeadmin-password` file is unrecoverable.

## After install

The `gitops/kustomization.yaml` image tag still points at an image from a previous
cluster, so the app pods will briefly **ImagePullBackOff** until the first pipeline
runs. This self-corrects: the script seeds the GitLab project, which triggers a
pipeline that builds an image into the new cluster's registry and rewrites the tag.

To verify end-to-end, edit the message in `sample-app/app.py`, then:

```bash
git commit -am "test pipeline" && git push
```

Watch it flow:
1. **GitHub Action** → `https://github.com/<repo>/actions`
2. **GitLab pipeline** → `https://gitlab.apps.<domain>/root/sample-app/-/pipelines`
3. **ArgoCD** → `https://openshift-gitops-server-openshift-gitops.apps.<domain>`
4. **App** → `https://sample-app-sample-app.apps.<domain>`

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `update-manifest` fails "Invalid username or token" | The GitLab CI variable `GITHUB_TOKEN` is stale. Re-run the script or update it after rotating the GitHub PAT. |
| GitHub push rejected, "without `workflow` scope" | PAT lacks `workflow` scope. |
| Action didn't trigger | The commit that *adds* a workflow often doesn't run it; push once more. Also the path filter only matches `sample-app/**`. |
| ArgoCD `OutOfSync`, RBAC forbidden | Namespace needs `argocd.argoproj.io/managed-by=openshift-gitops` (already in the manifest). |
| GitLab webservice never ready | Check `oc get pods -n gitlab-system`; usually resource pressure or the migrations job. |
| `shared-secrets` job stuck, `FailedCreate ... forbidden` | The `gitlab-anyuid` SCC isn't bound. GitLab runs pods as UID 65534 **and** sets legacy seccomp annotations, so neither `restricted-v2` nor built-in `anyuid` accepts them. `install.sh` applies `deploy/gitlab/00-scc-gitlab-anyuid.yaml` and binds it to `system:serviceaccounts:gitlab-system`. |
| Helm `failed pre-install: timed out` | Same SCC issue above — the hook pod could never be created. Fix the SCC, `helm uninstall gitlab -n gitlab-system`, re-run. |
