# Installing on an OpenShift cluster

One command deploys the whole reference pipeline: OpenShift GitOps (ArgoCD),
an in-cluster GitLab, a privileged GitLab Runner, ONE GitLab project (monorepo)
seeded from `templates/`, dev + prod ArgoCD Applications, and a GitLab → ArgoCD
push webhook — with JFrog Artifactory as the image registry.

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift cluster | 4.14+, cluster-admin. Tested on 4.21 (drop-ins for 4.12 in troubleshooting below). |
| `oc`, `helm`, `git`, `openssl`, `python3` | on `PATH` |
| Cluster resources | ~8 vCPU / 16 GiB free. GitLab bundles PostgreSQL, Redis, MinIO, Gitaly. |
| JFrog registry | JFrog Cloud (free tier is fine) or self-hosted Artifactory with a Docker repo |

## Credentials setup — one-time

Save your JFrog credentials outside the repo (the installer reads them):

```bash
mkdir -p ~/.config/ocp-clusters
cat > ~/.config/ocp-clusters/jfrog-creds.txt <<EOF
JFROG_URL=yourname.jfrog.io
JFROG_REPO=your-docker-repo
JFROG_USER=you@example.com
JFROG_TOKEN=<jfrog identity token or api key with push+pull>
EOF
chmod 600 ~/.config/ocp-clusters/jfrog-creds.txt
```

`JFROG_URL` is the host only (no `https://`). `JFROG_REPO` is the Docker
repository name *inside* Artifactory.

## Run

```bash
oc login --token=sha256~... --server=https://api.<cluster>:6443
./install.sh
```

`install.sh` is **idempotent** — safe to re-run at any point. It writes all
generated credentials to `.install-output/credentials.txt` (mode 600,
gitignored). Expected duration: **15–25 min on a fresh cluster**, mostly
waiting for GitLab.

## What it does

| # | Stage | Notes |
|---|---|---|
| 1 | OpenShift GitOps operator | Idempotent — cluster-wide, waits for CSV + argocd-server |
| 2 | `sample-app-dev` + `sample-app-prod` namespaces | Labelled for ArgoCD, each with a JFrog `docker-registry` pull secret |
| 3 | `gitlab-system` namespace + custom `gitlab-anyuid` SCC | GitLab pods need UID 65534 AND legacy seccomp — neither restricted-v2 nor built-in anyuid allow both |
| 4 | Self-signed wildcard cert for `*.<apps-domain>` | Auto-regenerated if a previous cert's SAN doesn't match the current cluster |
| 5 | GitLab via Helm (chart 9.11.8) | Chart 10+ dropped bundled PG/Redis/MinIO — we pin 9.11.8 |
| 6 | Root PAT + GitLab Runner registration | Reuses existing runner if one is registered |
| 7 | GitLab Runner Helm chart 0.88.4 | Kubernetes executor, `gitlab-runner-sa` with privileged SCC |
| 8 | **One** GitLab project (`root/sample-app`, monorepo), seed from `templates/`, set 4 CI variables, create a `read_repository` deploy token for ArgoCD | Skips seeding if the project already has commits — delete the project in GitLab to reseed |
| 9 | ArgoCD wiring: trust GitLab CA, Repository secret, dev + prod Applications, GitLab push webhook | Both Applications target the same repo, different `path:` |

## After install

Credentials live at `.install-output/credentials.txt`. The output prints the
same info to your terminal. Consider copying it to
`~/.config/ocp-clusters/<name>/` so a cluster reprovision doesn't lose it.

Try it end to end:

```bash
# 1. Clone the monorepo from GitLab
git -c http.sslVerify=false clone \
    https://oauth2:<GITLAB_ROOT_PAT>@<GITLAB_HOST>/root/sample-app.git

# 2. Edit app/app.py MESSAGE
# 3. Commit + push
git commit -am "test: change message" && git push

# 4. Watch it flow:
#    - GitLab pipeline builds app/ + pushes to JFrog
#    - update-manifest bumps gitops/overlays/dev/kustomization.yaml
#      (pushes back to the SAME repo using CI_JOB_TOKEN)
#    - ArgoCD auto-syncs sample-app-dev
#    - app is live at https://sample-app-sample-app-dev.apps.<cluster>
```

To promote dev → prod (simulates what a release manager does):

```bash
cd sample-app
DEV_TAG=$(grep -E '^\s*newTag:' gitops/overlays/dev/kustomization.yaml \
          | awk '{print $2}' | tr -d '"')
sed -i.bak -E "s|(newTag:)[[:space:]]*\"[^\"]*\"|\\1 \"$DEV_TAG\"|" \
    gitops/overlays/prod/kustomization.yaml
git commit -am "promote: sample-app $DEV_TAG dev -> prod [skip ci]"
git push

# ArgoCD's prod Application does NOT auto-sync (by design).
# Sync it manually from the UI, or:
oc annotate application sample-app-prod -n openshift-gitops \
   argocd.argoproj.io/refresh=hard --overwrite
oc patch application sample-app-prod -n openshift-gitops --type=merge \
   -p '{"operation":{"sync":{"revision":"main"}}}'
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `helm ... failed pre-install: timed out` | `gitlab-anyuid` SCC isn't bound. Check `oc get scc gitlab-anyuid`. Then `helm uninstall gitlab -n gitlab-system` + re-run. |
| ArgoCD repo error `x509: certificate is valid for *.apps.<other>...` | Stale cert in `.install-output/certs/`. Delete the dir and re-run — install.sh regenerates for the current apps domain. |
| CI's `update-manifest` fails on `git push` with 403 | `CI_JOB_TOKEN` isn't allowed to push. In GitLab UI: Project → Settings → CI/CD → Job token permissions → allow the current project. |
| CI pipeline stays pending, no jobs | Push happened on a branch other than `main`, or commit message contains `[skip ci]`, or only `gitops/**` changed. Workflow `rules:` filter on `app/**` + `.gitlab-ci.yml` — deployment-bookkeeping commits don't trigger builds. |
| Dev pods `ImagePullBackOff` right after install | Expected briefly — no image built yet. Push a commit; first pipeline builds + tags + syncs dev. |
| GitLab webservice never ready | Slow cluster. `install.sh` waits up to 45 min. Check `oc get pods -n gitlab-system`; usually PVC/migrations. |
| Running on OpenShift 4.12 | Older OpenShift GitOps operator (v1.8/1.9) — should just work; older `restricted` SCC instead of `restricted-v2`. Custom `gitlab-anyuid` SCC unchanged. If chart 9.11.8 rejects K8s 1.25, try chart 8.x. |

## Reprovisioning to a new cluster

Same command — `./install.sh` — after you `oc login` to the new cluster.
Everything is auto-detected from the cluster's apps domain and regenerated
where necessary, no code edits.

Before running the second time, if you plan to keep the old cluster
credentials around, back them up:
```bash
cp .install-output/credentials.txt ~/.config/ocp-clusters/<old-cluster-name>/
rm -rf .install-output/certs   # force regeneration for the new cluster
```
