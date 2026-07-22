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
| 3 | GitLab operator + CRD |
| 4 | Self-signed CA + wildcard cert for `*.<apps-domain>` → TLS secrets |
| 5 | `GitLab` CR (chart 9.11.7) exposed via OpenShift Routes |
| 6 | GitLab root PAT (rails console) + instance runner registration |
| 7 | GitLab Runner (Helm 0.76.3), Kubernetes executor, **privileged** SCC for buildah |
| 8 | GitLab project `root/sample-app`, unprotect `main`, CI variables |
| 9 | GitHub `GITLAB_PUSH_TOKEN` secret + `GITLAB_URL` variable, ArgoCD Application |

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
