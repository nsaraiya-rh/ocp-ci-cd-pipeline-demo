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
| 8 | **One** GitLab project (`root/sample-app`, monorepo), seed from `templates/`, **create the `dev` branch**, set 4 CI variables, create a `read_repository` deploy token for ArgoCD | Skips seeding if the project already has commits — delete the project in GitLab to reseed |
| 9 | ArgoCD wiring: trust GitLab CA, Repository secret, dev + prod Applications, GitLab push webhook | dev Application tracks the **`dev` branch**, prod tracks **`main`** |

## After install

Credentials live at `.install-output/credentials.txt`. The output prints the
same info to your terminal. Consider copying it to
`~/.config/ocp-clusters/<name>/` so a cluster reprovision doesn't lose it.

Try it end to end (environment-branch flow):

```bash
# 1. Clone the DEV branch (developers work here)
git -c http.sslVerify=false clone -b dev \
    https://oauth2:<GITLAB_ROOT_PAT>@<GITLAB_HOST>/root/sample-app.git
cd sample-app

# 2. Edit app/app.py MESSAGE, commit + push to dev
git commit -am "test: change message" && git push origin dev

# 3. Watch DEV deploy:
#    - build-image  builds app/ + pushes to JFrog :<sha>
#    - deploy-dev   bumps gitops/overlays/dev on the dev branch (CI_JOB_TOKEN)
#    - ArgoCD (tracking `dev`) auto-syncs
#    - live at https://sample-app-sample-app-dev.apps.<cluster>
```

Promote dev → prod — done through an MR (the governance gate):

```
# In the GitLab UI: Merge requests → New → source `dev`, target `main`
# → get it approved → Merge.
#
# The promote-prod job (ref=main) then copies dev's image tag into
# gitops/overlays/prod — NO rebuild, the exact image dev validated.
```

Then deploy prod with a deliberate Sync — prod does **not** auto-deploy:

```bash
# In the ArgoCD UI: open sample-app-prod (now OutOfSync) → Sync.
# Or from the CLI:
oc patch application sample-app-prod -n openshift-gitops --type=merge \
   -p '{"operation":{"sync":{"revision":"main"}}}'
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `helm ... failed pre-install: timed out` | `gitlab-anyuid` SCC isn't bound. Check `oc get scc gitlab-anyuid`. Then `helm uninstall gitlab -n gitlab-system` + re-run. |
| ArgoCD repo error `x509: certificate is valid for *.apps.<other>...` | Stale cert in `.install-output/certs/`. Delete the dir and re-run — install.sh regenerates for the current apps domain. |
| CI's `update-manifest` fails on `git push` with 403 | `CI_JOB_TOKEN` isn't allowed to push. In GitLab UI: Project → Settings → CI/CD → Job token permissions → allow the current project. |
| No build after committing | `build-image`/`deploy-dev` run only on the **`dev`** branch with an `app/**` change. A commit on a feature branch, on `main`, with `[skip ci]`, or touching only `gitops/**` will not build. Merge to `dev` (or commit there) to build; merge to `main` runs only `promote-prod`. |
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
