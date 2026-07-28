#!/usr/bin/env bash
#
# One-command bootstrap of the CI/CD demo on an OpenShift cluster.
#
#   Deploys: OpenShift GitOps (ArgoCD), in-cluster GitLab, GitLab Runner,
#            a self-signed wildcard TLS cert, two GitLab projects seeded from
#            templates/, a JFrog pull secret in dev + prod namespaces, and
#            two ArgoCD Applications (dev auto-sync, prod manual-sync).
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
# Version: v2 — GitLab-as-source-of-truth, JFrog registry, dev+prod overlays.

set -euo pipefail

# ---------------------------------------------------------------- config ----
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-9.11.8}"   # bundles PG/Redis/MinIO
RUNNER_CHART_VERSION="${RUNNER_CHART_VERSION:-0.88.4}"   # matches GitLab 18.11
GITLAB_NS="gitlab-system"
RUNNER_NS="gitlab-runner"
APP_PROJECT="sample-app"
GITOPS_PROJECT="sample-app-gitops"
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
  # Let openshift-gitops ArgoCD manage resources in this namespace
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
# GitLab pods run as UID 65534 AND set legacy seccomp annotations —
# restricted-v2 rejects the UID, built-in anyuid rejects the seccomp annotation.
oc apply -f "${REPO_DIR}/deploy/gitlab/00-scc-gitlab-anyuid.yaml" >/dev/null
oc adm policy add-scc-to-group gitlab-anyuid "system:serviceaccounts:${GITLAB_NS}" >/dev/null
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
ok "namespace ${GITLAB_NS} ready, gitlab-anyuid SCC bound, helm repo added"

# --------------------------------------------------- 4 self-signed TLS ------
log "4/9  Self-signed TLS for *.${APPS_DOMAIN}"
CERT_DIR="${OUT_DIR}/certs"; mkdir -p "$CERT_DIR"
# Regenerate if the existing cert's SAN doesn't cover the current apps domain
# (happens when .install-output/ was carried across clusters).
if [[ -f "${CERT_DIR}/tls.crt" ]]; then
  if ! openssl x509 -in "${CERT_DIR}/tls.crt" -noout -ext subjectAltName 2>/dev/null \
       | grep -q "DNS:\*\.${APPS_DOMAIN}"; then
    warn "existing cert is for a different domain — regenerating"
    rm -f "${CERT_DIR}/tls.crt" "${CERT_DIR}/tls.key" "${CERT_DIR}/ca.crt" \
          "${CERT_DIR}/ca.key" "${CERT_DIR}/fullchain.crt" "${CERT_DIR}/tls.csr" \
          "${CERT_DIR}/san.ext" "${CERT_DIR}/ca.srl"
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
for _ in $(seq 1 225); do   # 225*12s = 45 min upper bound
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
t = u.personal_access_tokens.create!(scopes: ['api','write_repository'], name: 'installer-$(date +%s)', expires_at: 365.days.from_now);
t.set_token('${GITLAB_PAT}'); t.save!;
" >/dev/null 2>&1 || die "failed to create GitLab root PAT"
ok "root PAT created"

gl_api() { curl -sk -H "PRIVATE-TOKEN: ${GITLAB_PAT}" "$@"; }

# Runner: create if none exists yet
if [[ -z "$(gl_api "${GITLAB_URL}/api/v4/runners/all?type=instance_type" | tr ',' '\n' | grep -c '"id"' || true)" ]] \
   || [[ "$(gl_api "${GITLAB_URL}/api/v4/runners/all?type=instance_type" | tr ',' '\n' | grep -c '"id"')" == "0" ]]; then
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
# Chart projects both keys; runner-registration-token must exist (empty allowed).
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

# ----------------------------------- 8 GitLab projects: create + seed + vars ---
log "8/9  GitLab projects, seed content, CI variables"

create_or_get_project() {                     # $1 = project name  → echoes project id
  local name="$1"
  local existing new
  existing=$(gl_api "${GITLAB_URL}/api/v4/projects?search=${name}&owned=true" \
             | python3 -c "import sys,json;p=[x for x in json.load(sys.stdin) if x['path']=='${name}'];print(p[0]['id'] if p else '')" 2>/dev/null)
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return
  fi
  # Parse the project id from POST response with python — a POST /projects
  # response contains multiple "id" fields (project, namespace, owner), so
  # sed's greedy .* matches the wrong one (typically the root user's id=1).
  new=$(gl_api --request POST "${GITLAB_URL}/api/v4/projects" \
        --data "name=${name}" --data "path=${name}" \
        --data "visibility=private" --data "initialize_with_readme=false")
  echo "$new" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null
}

APP_PID="$(create_or_get_project "$APP_PROJECT")"
GITOPS_PID="$(create_or_get_project "$GITOPS_PROJECT")"
[[ -n "$APP_PID"    ]] || die "failed to create/find ${APP_PROJECT} project"
[[ -n "$GITOPS_PID" ]] || die "failed to create/find ${GITOPS_PROJECT} project"
ok "project ${APP_PROJECT} (id ${APP_PID}), ${GITOPS_PROJECT} (id ${GITOPS_PID})"

# Unprotect main on both — the initial seed does a force push
for pid in "$APP_PID" "$GITOPS_PID"; do
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${pid}/protected_branches/main" >/dev/null 2>&1 || true
done

# Seed the app project (only if it has no commits yet)
seed_project() {                              # $1 = pid  $2 = local seed dir  $3 = project path (e.g. sample-app)
  local pid="$1" src="$2" pname="$3"
  local commits
  commits=$(gl_api "${GITLAB_URL}/api/v4/projects/${pid}/repository/commits?per_page=1" | grep -c '"id"' || true)
  if [[ "$commits" -gt 0 ]]; then
    warn "${pname} already has commits — skipping seed (delete project + re-run to reseed)"
    return
  fi
  local tmp; tmp=$(mktemp -d)
  cp -R "$src"/. "$tmp"/
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

# Render the JFrog image path into the gitops overlays before seeding
RENDERED_GITOPS="${OUT_DIR}/gitops-seed"
rm -rf "$RENDERED_GITOPS"
cp -R "${REPO_DIR}/templates/gitops" "$RENDERED_GITOPS"
find "$RENDERED_GITOPS" -type f -name '*.yaml' -exec sed -i.bak "s|__IMAGE_REPO__|${IMAGE_REPO}|g" {} \;
find "$RENDERED_GITOPS" -name '*.bak' -delete

seed_project "$APP_PID"    "${REPO_DIR}/templates/sample-app" "$APP_PROJECT"
seed_project "$GITOPS_PID" "$RENDERED_GITOPS"                 "$GITOPS_PROJECT"

# Project Access Token on gitops repo — used by BOTH:
#   - sample-app CI: to push tag bumps into overlays/dev/kustomization.yaml
#   - ArgoCD:        to clone the private repo (needs read; the token grants that too)
# NOTE: deploy tokens are read-only for repositories in GitLab — write_repository
# is not a valid deploy-token scope. Project access tokens are the right primitive.
GITOPS_PAT_NAME="ci-writer"
# Idempotency: revoke any prior project access token with this name (can't retrieve value)
for tid in $(gl_api "${GITLAB_URL}/api/v4/projects/${GITOPS_PID}/access_tokens" \
             | python3 -c "import sys,json;[print(t['id']) for t in json.load(sys.stdin) if t.get('name')=='${GITOPS_PAT_NAME}']" 2>/dev/null); do
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${GITOPS_PID}/access_tokens/${tid}" >/dev/null || true
done
# expires_at is required by GitLab 16+; use 1 year (max allowed on many instances is 365d)
GITOPS_PAT_EXPIRES=$(python3 -c "from datetime import date,timedelta;print((date.today()+timedelta(days=365)).isoformat())")
GITOPS_PAT_JSON=$(gl_api --request POST "${GITLAB_URL}/api/v4/projects/${GITOPS_PID}/access_tokens" \
  --data "name=${GITOPS_PAT_NAME}" \
  --data "access_level=40" \
  --data "expires_at=${GITOPS_PAT_EXPIRES}" \
  --data "scopes[]=api" --data "scopes[]=write_repository" --data "scopes[]=read_repository")
GITOPS_DEPLOY_TOKEN=$(echo "$GITOPS_PAT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
[[ -n "$GITOPS_DEPLOY_TOKEN" ]] \
  || die "failed to create project access token on ${GITOPS_PROJECT}: ${GITOPS_PAT_JSON}"
ok "project access token '${GITOPS_PAT_NAME}' created on ${GITOPS_PROJECT}"

# CI variables on the app project — delete+create is idempotent AND actually
# updates the value. (Previous POST||PUT idiom broke because curl returns exit
# 0 on HTTP 409, so PUT never ran and stale values persisted across re-runs.)
set_var() {                                  # $1 project id  $2 key  $3 value
  local pid="$1" k="$2" v="$3"
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${pid}/variables/$k" >/dev/null 2>&1 || true
  gl_api --request POST "${GITLAB_URL}/api/v4/projects/${pid}/variables" \
    --data "key=$k" --data-urlencode "value=$v" --data "masked=false" --data "protected=false" >/dev/null
}
set_var "$APP_PID" JFROG_URL           "$JFROG_URL"
set_var "$APP_PID" JFROG_REPO          "$JFROG_REPO"
set_var "$APP_PID" JFROG_USER          "$JFROG_USER"
set_var "$APP_PID" JFROG_TOKEN         "$JFROG_TOKEN"
set_var "$APP_PID" GITOPS_DEPLOY_TOKEN "$GITOPS_DEPLOY_TOKEN"
set_var "$APP_PID" GITOPS_PROJECT_URL  "${GITLAB_HOST}/root/${GITOPS_PROJECT}"
ok "CI variables set on ${APP_PROJECT}"

# --------------------------------------------------- 9 ArgoCD Applications ---
log "9/9  ArgoCD wiring (GitLab CA trust, Repository secret, Applications, webhook)"

# 9a. Trust GitLab CA in ArgoCD so it can clone https://gitlab.apps.*
CA_PEM=$(cat "${CERT_DIR}/ca.crt")
oc get cm argocd-tls-certs-cm -n openshift-gitops >/dev/null 2>&1 || \
  oc create configmap argocd-tls-certs-cm -n openshift-gitops >/dev/null
oc patch cm argocd-tls-certs-cm -n openshift-gitops --type=merge \
  -p "$(python3 -c "import json,sys;print(json.dumps({'data':{'${GITLAB_HOST}':sys.stdin.read()}}))" <<< "$CA_PEM")" >/dev/null

# 9b. Repository secret so ArgoCD can read the private gitops project
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-sample-app-gitops
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITLAB_URL}/root/${GITOPS_PROJECT}.git
  username: oauth2
  password: ${GITOPS_DEPLOY_TOKEN}
EOF

# 9c. Both Applications (dev + prod), with rendered GitLab host
for app in sample-app-dev sample-app-prod; do
  sed "s|__GITLAB_HOST__|${GITLAB_HOST}|g" "${REPO_DIR}/deploy/argocd/${app}.yaml" \
    | oc apply -f - >/dev/null
done
ok "ArgoCD dev + prod Applications applied"

# 9d. ArgoCD webhook secret + GitLab -> ArgoCD project webhook (instant sync)
WEBHOOK_SECRET="$(openssl rand -hex 20)"
oc patch secret argocd-secret -n openshift-gitops --type merge \
  -p "{\"stringData\":{\"webhook.gitlab.secret\":\"${WEBHOOK_SECRET}\"}}" >/dev/null 2>&1
oc rollout restart deploy/openshift-gitops-server -n openshift-gitops >/dev/null 2>&1
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=120s >/dev/null 2>&1
ARGO_WEBHOOK_URL="https://${ARGO_HOST}/api/webhook"
# Remove any existing webhook on the gitops project first (idempotency)
for hid in $(gl_api "${GITLAB_URL}/api/v4/projects/${GITOPS_PID}/hooks" | python3 -c "import sys,json;[print(h['id']) for h in json.load(sys.stdin) if h['url'].endswith('/api/webhook')]" 2>/dev/null); do
  gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${GITOPS_PID}/hooks/${hid}" >/dev/null 2>&1 || true
done
gl_api --request POST "${GITLAB_URL}/api/v4/projects/${GITOPS_PID}/hooks" \
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
GITLAB_GITOPS_PROJECT_ID=${GITOPS_PID}
GITLAB_RUNNER_TOKEN=${RUNNER_TOKEN}
GITOPS_DEPLOY_TOKEN=${GITOPS_DEPLOY_TOKEN}

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

  Projects  ${GITLAB_URL}/root/${APP_PROJECT}         (application source + CI)
            ${GITLAB_URL}/root/${GITOPS_PROJECT}      (deployment manifests)

  Registry  ${JFROG_URL}/${JFROG_REPO}                (JFrog Artifactory)

  Apps      https://sample-app-${DEV_NS}.${APPS_DOMAIN}    (dev, auto-sync)
            https://sample-app-${PROD_NS}.${APPS_DOMAIN}   (prod, manual sync)

  Credentials saved to: ${OUT_DIR}/credentials.txt

  Next:
    1. Edit sample-app/app.py in GitLab (${GITLAB_URL}/root/${APP_PROJECT})
       commit + push to main. CI builds → pushes to JFrog → bumps
       sample-app-gitops/overlays/dev/kustomization.yaml → ArgoCD deploys dev.
    2. To promote dev -> prod: open MR in ${GITOPS_PROJECT} that copies the
       current dev newTag into overlays/prod/kustomization.yaml, review, merge.
       Then sync the sample-app-prod Application in ArgoCD (UI/CLI).
EOF
