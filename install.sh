#!/usr/bin/env bash
#
# One-command bootstrap of the CI/CD demo on an OpenShift cluster.
#
#   Deploys: OpenShift GitOps (ArgoCD), in-cluster GitLab, GitLab Runner,
#            a self-signed wildcard TLS cert, ONE monorepo GitLab project
#            seeded from templates/, a JFrog pull secret in dev + prod
#            namespaces, and two ArgoCD Applications (dev auto-sync,
#            prod manual-sync).
#
#   Registry: JFrog Artifactory Cloud (credentials from a local file).
#
# Usage:
#   oc login --token=... --server=https://api.<cluster>:6443
#   export JFROG_CREDS_FILE=~/.config/ocp-clusters/jfrog-creds.txt   # optional; default shown
#   ./install.sh
#
# Idempotent: safe to re-run. Generated credentials are written to
# .install-output/credentials.txt (mode 600, gitignored).
#
# Version: v3 — MONOREPO layout (app + gitops in one GitLab project).
# CI push-back to gitops uses built-in CI_JOB_TOKEN (no project access token).

set -euo pipefail

# ---------------------------------------------------------------- config ----
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-9.11.8}"   # bundles PG/Redis/MinIO
RUNNER_CHART_VERSION="${RUNNER_CHART_VERSION:-0.88.4}"   # matches GitLab 18.11
GITLAB_NS="gitlab-system"
RUNNER_NS="gitlab-runner"
APP_PROJECT="sample-app"     # single project — contains both app/ and gitops/
DEV_NS="sample-app-dev"
PROD_NS="sample-app-prod"

JFROG_CREDS_FILE="${JFROG_CREDS_FILE:-$HOME/.config/ocp-clusters/jfrog-creds.txt}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${REPO_DIR}/.install-output"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- preflight ----
log "Preflight"
command -v oc   >/dev/null || die "oc not found in PATH"
command -v helm >/dev/null || die "helm not found in PATH"
command -v git  >/dev/null || die "git not found in PATH"

oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (use 'oc login')"
oc auth can-i create clusterrolebinding >/dev/null 2>&1 \
  || die "current user lacks cluster-admin"
ok "logged in as $(oc whoami) @ $(oc whoami --show-server)"

[[ -f "$JFROG_CREDS_FILE" ]] || die "JFrog creds file not found: $JFROG_CREDS_FILE"
# shellcheck disable=SC1090
source "$JFROG_CREDS_FILE"
: "${JFROG_URL:?not set in $JFROG_CREDS_FILE}"
: "${JFROG_REPO:?not set in $JFROG_CREDS_FILE}"
: "${JFROG_USER:?not set in $JFROG_CREDS_FILE}"
: "${JFROG_TOKEN:?not set in $JFROG_CREDS_FILE}"
IMAGE_REPO="${JFROG_URL}/${JFROG_REPO}/sample-app"
ok "JFrog: ${JFROG_URL}/${JFROG_REPO} (user: ${JFROG_USER})"

APPS_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
[[ -n "$APPS_DOMAIN" ]] || die "could not detect cluster apps domain"
GITLAB_HOST="gitlab.${APPS_DOMAIN}"
GITLAB_URL="https://${GITLAB_HOST}"
ok "apps domain : ${APPS_DOMAIN}"
ok "GitLab      : ${GITLAB_URL}"

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"

# --------------------------------------------------------------- 1 ArgoCD ---
log "1/9  OpenShift GitOps (ArgoCD)"
oc apply -f "${REPO_DIR}/deploy/argocd/01-operator-subscription.yaml" >/dev/null
printf '    waiting for operator'
for _ in $(seq 1 60); do
  oc get csv -n openshift-operators 2>/dev/null | grep -qi 'gitops.*Succeeded' && break
  printf '.'; sleep 10
done; echo
oc get csv -n openshift-operators 2>/dev/null | grep -qi 'gitops.*Succeeded' \
  || die "OpenShift GitOps operator did not become ready"
printf '    waiting for argocd server'
for _ in $(seq 1 60); do
  [[ "$(oc get deploy openshift-gitops-server -n openshift-gitops \
        -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ]] 2>/dev/null && break
  printf '.'; sleep 10
done; echo
ARGO_HOST="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)"
ARGO_PW="$(oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || true)"
ok "ArgoCD: https://${ARGO_HOST}"

# ------------------------------------------ 2 app namespaces + pull secrets ---
log "2/9  App namespaces (dev + prod) with JFrog pull secrets"
for ns in "$DEV_NS" "$PROD_NS"; do
  oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label namespace "$ns" argocd.argoproj.io/managed-by=openshift-gitops --overwrite >/dev/null
  oc create secret docker-registry jfrog-pull -n "$ns" \
    --docker-server="$JFROG_URL" \
    --docker-username="$JFROG_USER" \
    --docker-password="$JFROG_TOKEN" \
    --docker-email="$JFROG_USER" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "namespace ${ns} + jfrog-pull secret ready"
done

# --------------------------------------------------------------- 3 GitLab ---
log "3/9  GitLab namespace + custom SCC + Helm repo"
oc create namespace "$GITLAB_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -f "${REPO_DIR}/deploy/gitlab/00-scc-gitlab-anyuid.yaml" >/dev/null
oc adm policy add-scc-to-group gitlab-anyuid "system:serviceaccounts:${GITLAB_NS}" >/dev/null
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
ok "namespace ${GITLAB_NS} ready, gitlab-anyuid SCC bound, helm repo added"

# --------------------------------------------------- 4 self-signed TLS ------
log "4/9  Self-signed TLS for *.${APPS_DOMAIN}"
CERT_DIR="${OUT_DIR}/certs"; mkdir -p "$CERT_DIR"
# Regenerate if cert's SAN doesn't cover current apps domain (from a prior cluster)
if [[ -f "${CERT_DIR}/tls.crt" ]]; then
  if ! openssl x509 -in "${CERT_DIR}/tls.crt" -noout -ext subjectAltName 2>/dev/null \
       | grep -q "DNS:\*\.${APPS_DOMAIN}"; then
    warn "existing cert is for a different domain — regenerating"
    rm -f "${CERT_DIR}"/{tls.crt,tls.key,ca.crt,ca.key,fullchain.crt,tls.csr,san.ext,ca.srl}
  fi
fi
if [[ ! -f "${CERT_DIR}/tls.crt" ]]; then
  openssl genrsa -out "${CERT_DIR}/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "${CERT_DIR}/ca.key" -sha256 -days 825 \
    -out "${CERT_DIR}/ca.crt" -subj "/CN=gitlab-demo-ca/O=cicd-demo" 2>/dev/null
  openssl genrsa -out "${CERT_DIR}/tls.key" 2048 2>/dev/null
  openssl req -new -key "${CERT_DIR}/tls.key" -out "${CERT_DIR}/tls.csr" \
    -subj "/CN=*.${APPS_DOMAIN}" 2>/dev/null
  printf 'subjectAltName=DNS:*.%s,DNS:%s\nextendedKeyUsage=serverAuth\n' \
    "$APPS_DOMAIN" "$APPS_DOMAIN" > "${CERT_DIR}/san.ext"
  openssl x509 -req -in "${CERT_DIR}/tls.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial -out "${CERT_DIR}/tls.crt" -days 825 -sha256 -extfile "${CERT_DIR}/san.ext" 2>/dev/null
  cat "${CERT_DIR}/tls.crt" "${CERT_DIR}/ca.crt" > "${CERT_DIR}/fullchain.crt"
fi
oc create secret tls gitlab-wildcard-tls -n "$GITLAB_NS" \
  --cert="${CERT_DIR}/fullchain.crt" --key="${CERT_DIR}/tls.key" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create secret generic gitlab-selfsigned-ca -n "$GITLAB_NS" \
  --from-file=gitlab-demo-ca.crt="${CERT_DIR}/ca.crt" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
ok "TLS + CA secrets in $GITLAB_NS"

# ---------------------------------------------------------- 5 GitLab install ---
log "5/9  GitLab (Helm chart ${GITLAB_CHART_VERSION}) — takes ~10-20 min on first run"
sed -e "s|__APPS_DOMAIN__|${APPS_DOMAIN}|g" \
    "${REPO_DIR}/deploy/gitlab/02-gitlab-values.yaml" > "${OUT_DIR}/gitlab-values.rendered.yaml"
helm upgrade --install gitlab gitlab/gitlab \
  --version "$GITLAB_CHART_VERSION" -n "$GITLAB_NS" \
  -f "${OUT_DIR}/gitlab-values.rendered.yaml" \
  --timeout 20m >/dev/null
printf '    waiting for gitlab webservice'
for _ in $(seq 1 225); do
  ready=$(oc get deploy -n "$GITLAB_NS" -l app=webservice \
          -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)
  [[ -n "$ready" && "$ready" -ge 1 ]] && break
  printf '.'; sleep 12
done; echo
ready=$(oc get deploy -n "$GITLAB_NS" -l app=webservice \
        -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)
[[ -n "$ready" && "$ready" -ge 1 ]] \
  || die "GitLab webservice never became available (oc get pods -n ${GITLAB_NS})"
GITLAB_ROOT_PW="$(oc get secret gitlab-gitlab-initial-root-password -n "$GITLAB_NS" -o jsonpath='{.data.password}' | base64 -d)"
ok "GitLab up at ${GITLAB_URL} (root / ${GITLAB_ROOT_PW})"

# ------------------------------------------------------ 6 GitLab API prep ---
log "6/9  GitLab root PAT + runner"
TOOLBOX="$(oc get pod -n "$GITLAB_NS" -l app=toolbox -o name | head -1)"
[[ -n "$TOOLBOX" ]] || die "gitlab toolbox pod not found"
GITLAB_PAT="glpat-$(openssl rand -hex 10)"
oc exec -n "$GITLAB_NS" "$TOOLBOX" -c toolbox -- gitlab-rails runner "
u = User.find_by_username('root');
t = u.personal_access_tokens.create!(scopes: ['api','write_repository','read_repository'], name: 'installer-$(date +%s)', expires_at: 365.days.from_now);
t.set_token('${GITLAB_PAT}'); t.save!;
" >/dev/null 2>&1 || die "failed to create GitLab root PAT"
ok "root PAT created"

gl_api() { curl -sk -H "PRIVATE-TOKEN: ${GITLAB_PAT}" "$@"; }

# Runner: reuse if any instance runner exists; else create fresh
if [[ "$(gl_api "${GITLAB_URL}/api/v4/runners/all?type=instance_type" | tr ',' '\n' | grep -c '"id"')" == "0" ]]; then
  RUNNER_TOKEN="$(gl_api --request POST "${GITLAB_URL}/api/v4/user/runners" \
    --data "runner_type=instance_type" --data "description=ocp-kubernetes-runner" \
    --data "run_untagged=true" --data "tag_list=ocp,buildah" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [[ -n "$RUNNER_TOKEN" ]] || die "failed to create GitLab runner"
  ok "instance runner registered"
else
  ok "instance runner already registered (reusing existing)"
  RUNNER_TOKEN="$(oc get secret gitlab-runner-secret -n "$RUNNER_NS" -o jsonpath='{.data.runner-token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$RUNNER_TOKEN" ]] || die "existing runner but no runner-token secret found; delete existing runner in GitLab UI and re-run"
fi

# --------------------------------------------------------------- 7 runner ---
log "7/9  GitLab Runner"
oc create namespace "$RUNNER_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create serviceaccount gitlab-runner-sa -n "$RUNNER_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc adm policy add-scc-to-user privileged -z gitlab-runner-sa -n "$RUNNER_NS" >/dev/null
oc create secret generic gitlab-runner-secret -n "$RUNNER_NS" \
  --from-literal=runner-token="$RUNNER_TOKEN" \
  --from-literal=runner-registration-token="" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
helm upgrade --install gitlab-runner gitlab/gitlab-runner \
  --version "$RUNNER_CHART_VERSION" -n "$RUNNER_NS" \
  -f "${REPO_DIR}/deploy/gitlab/03-runner-values.yaml" >/dev/null
printf '    waiting for runner'
for _ in $(seq 1 40); do
  [[ "$(oc get pods -n "$RUNNER_NS" -l app=gitlab-runner \
        -o jsonpath='{.items[-1:].status.containerStatuses[0].ready}' 2>/dev/null)" == "true" ]] && break
  printf '.'; sleep 10
done; echo
ok "runner online"

# ------------------------------------- 8 GitLab project: create + seed + vars ---
log "8/9  GitLab project (monorepo), seed content, CI variables, deploy token"

create_or_get_project() {
  local name="$1" existing new
  existing=$(gl_api "${GITLAB_URL}/api/v4/projects?search=${name}&owned=true" \
             | python3 -c "import sys,json;p=[x for x in json.load(sys.stdin) if x['path']=='${name}'];print(p[0]['id'] if p else '')" 2>/dev/null)
  if [[ -n "$existing" ]]; then
    echo "$existing"; return
  fi
  new=$(gl_api --request POST "${GITLAB_URL}/api/v4/projects" \
        --data "name=${name}" --data "path=${name}" \
        --data "visibility=private" --data "initialize_with_readme=false")
  echo "$new" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null
}

APP_PID="$(create_or_get_project "$APP_PROJECT")"
[[ -n "$APP_PID" ]] || die "failed to create/find ${APP_PROJECT} project"
ok "project ${APP_PROJECT} (id ${APP_PID})"

# Allow CI_JOB_TOKEN to push to this project's git repo. Default is FALSE for
# security; without this, update-manifest's `git push origin HEAD:main` returns
# "You are not allowed to push code to this project" (HTTP 403). Requires JSON
# body with a PUT (POST/form-encoded doesn't update this field on our GitLab).
curl -sk -X PUT "${GITLAB_URL}/api/v4/projects/${APP_PID}" \
  -H "PRIVATE-TOKEN: ${GITLAB_PAT}" -H "Content-Type: application/json" \
  -d '{"ci_push_repository_for_job_token_allowed":true}' >/dev/null 2>&1 || true

# Unprotect main so the initial seed can force-push
gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${APP_PID}/protected_branches/main" >/dev/null 2>&1 || true

# Seed the project (only if it has no commits yet)
seed_project() {
  local pid="$1" src="$2" pname="$3"
  local commits
  commits=$(gl_api "${GITLAB_URL}/api/v4/projects/${pid}/repository/commits?per_page=1" | grep -c '"id"' || true)
  if [[ "$commits" -gt 0 ]]; then
    warn "${pname} already has commits — skipping seed (delete project + re-run to reseed)"
    return
  fi
  local tmp; tmp=$(mktemp -d)
  cp -R "$src"/. "$tmp"/
  # Render __IMAGE_REPO__ placeholder in gitops overlays
  find "$tmp/gitops" -type f -name '*.yaml' -exec sed -i.bak "s|__IMAGE_REPO__|${IMAGE_REPO}|g" {} \; 2>/dev/null || true
  find "$tmp" -name '*.bak' -delete
  ( cd "$tmp"
    git init -q -b main
    git config user.email "installer@demo" && git config user.name "installer"
    git config http.sslVerify false
    git add -A
    git commit -q -m "initial seed from ocp-ci-cd-pipeline-demo templates"
    git push -q "https://oauth2:${GITLAB_PAT}@${GITLAB_HOST}/root/${pname}.git" main:main
  )
  rm -rf "$tmp"
  ok "seeded ${pname}"
}

seed_project "$APP_PID" "${REPO_DIR}/templates/sample-app" "$APP_PROJECT"

# Environment-branch model: create the long-lived `dev` branch from main.
# Developers commit to `dev` (drives the dev environment); an MR dev->main
# promotes to prod. ArgoCD's dev Application tracks this branch.
if [[ "$(gl_api "${GITLAB_URL}/api/v4/projects/${APP_PID}/repository/branches/dev" | grep -c '"name"')" == "0" ]]; then
  gl_api --request POST "${GITLAB_URL}/api/v4/projects/${APP_PID}/repository/branches?branch=dev&ref=main" >/dev/null
  ok "created dev branch (drives the dev environment)"
else
  ok "dev branch already exists"
fi

# CI variables — just the JFrog set. No cross-project token, no gitops URL.
set_var() {                                  # $1 project id  $2 key  $3 value
  local pid="$1" k="$2" v="$3"
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${pid}/variables/$k" >/dev/null 2>&1 || true
  gl_api --request POST "${GITLAB_URL}/api/v4/projects/${pid}/variables" \
    --data "key=$k" --data-urlencode "value=$v" --data "masked=false" --data "protected=false" >/dev/null
}
set_var "$APP_PID" JFROG_URL   "$JFROG_URL"
set_var "$APP_PID" JFROG_REPO  "$JFROG_REPO"
set_var "$APP_PID" JFROG_USER  "$JFROG_USER"
set_var "$APP_PID" JFROG_TOKEN "$JFROG_TOKEN"
ok "CI variables (4) set on ${APP_PROJECT}"

# Deploy token on the same project — read_repository — for ArgoCD to clone
DEPLOY_TOKEN_NAME="argocd-reader"
for tid in $(gl_api "${GITLAB_URL}/api/v4/projects/${APP_PID}/deploy_tokens" \
             | python3 -c "import sys,json;[print(t['id']) for t in json.load(sys.stdin) if t.get('name')=='${DEPLOY_TOKEN_NAME}']" 2>/dev/null); do
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${APP_PID}/deploy_tokens/${tid}" >/dev/null || true
done
DT_JSON=$(gl_api --request POST "${GITLAB_URL}/api/v4/projects/${APP_PID}/deploy_tokens" \
  --data "name=${DEPLOY_TOKEN_NAME}" \
  --data "username=argocd-reader" \
  --data "scopes[]=read_repository")
ARGOCD_DEPLOY_USER=$(echo "$DT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('username',''))" 2>/dev/null || true)
ARGOCD_DEPLOY_TOKEN=$(echo "$DT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
[[ -n "$ARGOCD_DEPLOY_TOKEN" ]] || die "failed to create deploy token: ${DT_JSON}"
ok "deploy token '${DEPLOY_TOKEN_NAME}' created for ArgoCD"

# --------------------------------------------------- 9 ArgoCD wiring --------
log "9/9  ArgoCD wiring (GitLab CA trust, Repository secret, Applications, webhook)"

# 9a. Trust GitLab CA in ArgoCD (dotted keys need special handling — apply full CM)
CA_PEM=$(cat "${CERT_DIR}/ca.crt")
python3 - <<PY | oc apply -f - >/dev/null
import yaml,sys
cm = {
  "apiVersion":"v1","kind":"ConfigMap",
  "metadata":{"name":"argocd-tls-certs-cm","namespace":"openshift-gitops",
              "labels":{"app.kubernetes.io/name":"argocd-tls-certs-cm",
                        "app.kubernetes.io/part-of":"argocd"}},
  "data":{"${GITLAB_HOST}":"""$CA_PEM"""}
}
print(yaml.dump(cm))
PY

# 9b. Repository secret so ArgoCD can read the private monorepo
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-sample-app
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITLAB_URL}/root/${APP_PROJECT}.git
  username: ${ARGOCD_DEPLOY_USER}
  password: ${ARGOCD_DEPLOY_TOKEN}
EOF

# 9c. Both Applications (dev + prod), same repo, different paths
for app in sample-app-dev sample-app-prod; do
  sed "s|__GITLAB_HOST__|${GITLAB_HOST}|g" "${REPO_DIR}/deploy/argocd/${app}.yaml" \
    | oc apply -f - >/dev/null
done
ok "ArgoCD dev + prod Applications applied"

# 9d. GitLab -> ArgoCD webhook (push events on the monorepo)
WEBHOOK_SECRET="$(openssl rand -hex 20)"
oc patch secret argocd-secret -n openshift-gitops --type merge \
  -p "{\"stringData\":{\"webhook.gitlab.secret\":\"${WEBHOOK_SECRET}\"}}" >/dev/null 2>&1
oc rollout restart deploy/openshift-gitops-server -n openshift-gitops >/dev/null 2>&1
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=120s >/dev/null 2>&1
ARGO_WEBHOOK_URL="https://${ARGO_HOST}/api/webhook"
for hid in $(gl_api "${GITLAB_URL}/api/v4/projects/${APP_PID}/hooks" \
             | python3 -c "import sys,json;[print(h['id']) for h in json.load(sys.stdin) if h['url'].endswith('/api/webhook')]" 2>/dev/null); do
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${APP_PID}/hooks/${hid}" >/dev/null 2>&1 || true
done
gl_api --request POST "${GITLAB_URL}/api/v4/projects/${APP_PID}/hooks" \
  --data "url=${ARGO_WEBHOOK_URL}" \
  --data "push_events=true" \
  --data "enable_ssl_verification=false" \
  --data "token=${WEBHOOK_SECRET}" >/dev/null
ok "GitLab -> ArgoCD webhook created (instant sync on gitops commits)"

# --------------------------------------------------------------- summary ----
cat > "${OUT_DIR}/credentials.txt" <<EOF
# Generated $(date). KEEP THIS FILE - these cannot be recovered later.
CLUSTER_API=$(oc whoami --show-server)
APPS_DOMAIN=${APPS_DOMAIN}

# --- OpenShift GitOps (ArgoCD) ---
ARGOCD_URL=https://${ARGO_HOST}
ARGOCD_USER=admin
ARGOCD_PASSWORD=${ARGO_PW}
ARGOCD_WEBHOOK_SECRET=${WEBHOOK_SECRET}

# --- GitLab (in-cluster) ---
GITLAB_URL=${GITLAB_URL}
GITLAB_USER=root
GITLAB_PASSWORD=${GITLAB_ROOT_PW}
GITLAB_ROOT_PAT=${GITLAB_PAT}
GITLAB_APP_PROJECT_ID=${APP_PID}
GITLAB_RUNNER_TOKEN=${RUNNER_TOKEN}
GITLAB_ARGOCD_DEPLOY_USER=${ARGOCD_DEPLOY_USER}
GITLAB_ARGOCD_DEPLOY_TOKEN=${ARGOCD_DEPLOY_TOKEN}

# --- JFrog Artifactory ---
JFROG_URL=${JFROG_URL}
JFROG_REPO=${JFROG_REPO}
JFROG_USER=${JFROG_USER}
IMAGE_REPO=${IMAGE_REPO}

# --- Apps ---
APP_DEV_URL=https://sample-app-${DEV_NS}.${APPS_DOMAIN}
APP_PROD_URL=https://sample-app-${PROD_NS}.${APPS_DOMAIN}
EOF
chmod 600 "${OUT_DIR}/credentials.txt"

log "Done"
cat <<EOF

  ArgoCD    https://${ARGO_HOST}
            admin / ${ARGO_PW}

  GitLab    ${GITLAB_URL}
            root / ${GITLAB_ROOT_PW}

  Project   ${GITLAB_URL}/root/${APP_PROJECT}   (monorepo: app/ + gitops/ + .gitlab-ci.yml)
            branch dev  -> dev environment    |    branch main -> prod environment

  Registry  ${JFROG_URL}/${JFROG_REPO}

  Apps      https://sample-app-${DEV_NS}.${APPS_DOMAIN}    (dev  · tracks 'dev' branch · auto-sync)
            https://sample-app-${PROD_NS}.${APPS_DOMAIN}   (prod · tracks 'main' branch · manual sync)

  Credentials saved to: ${OUT_DIR}/credentials.txt

  Next:
    1. On the 'dev' branch, edit app/app.py, commit + push.
       CI builds → pushes to JFrog → bumps overlays/dev on 'dev' →
       ArgoCD auto-deploys the dev environment.
    2. Promote to prod: open an MR 'dev' -> 'main', get it approved, merge.
       The promote-prod job copies dev's image tag into overlays/prod on main.
    3. Deploy prod: open the sample-app-prod Application in ArgoCD and click
       Sync (prod is manual-sync by design).
EOF
