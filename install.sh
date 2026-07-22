#!/usr/bin/env bash
#
# Bootstrap the whole CI/CD GitOps demo onto a fresh OpenShift cluster.
#
#   ArgoCD (OpenShift GitOps) + GitLab (operator) + GitLab Runner (buildah)
#   + OpenShift internal registry + the sample-app pipeline.
#
# Usage:
#   export GH_PAT=ghp_xxx          # GitHub PAT, scopes: repo + workflow
#   oc login --token=... --server=https://api.<cluster>:6443
#   ./install.sh
#
# Idempotent: safe to re-run. Generated credentials are written to
# .install-output/credentials.txt (gitignored) so they are never lost.

set -euo pipefail

# ---------------------------------------------------------------- config ----
GITHUB_REPO="${GITHUB_REPO:-nsaraiya-rh/ocp-ci-cd-pipeline-demo}"
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-9.11.8}"   # 10.x drops bundled PG/Redis/MinIO
RUNNER_CHART_VERSION="${RUNNER_CHART_VERSION:-0.88.4}"   # match GitLab 18.11
APP_NS="sample-app"
GITLAB_NS="gitlab-system"
RUNNER_NS="gitlab-runner"
GITLAB_PROJECT="sample-app"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/.install-output"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- preflight ----
log "Preflight"
command -v oc   >/dev/null || die "oc not found in PATH"
command -v helm >/dev/null || die "helm not found in PATH"
command -v git  >/dev/null || die "git not found in PATH"
[[ -n "${GH_PAT:-}" ]] || die "GH_PAT not set (GitHub PAT with 'repo' + 'workflow' scopes)"

oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (use 'oc login')"
oc auth can-i create clusterrolebinding >/dev/null 2>&1 \
  || die "current user lacks cluster-admin"
ok "logged in as $(oc whoami) @ $(oc whoami --show-server)"

APPS_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
[[ -n "$APPS_DOMAIN" ]] || die "could not detect cluster apps domain"
GITLAB_HOST="gitlab.${APPS_DOMAIN}"
GITLAB_URL="https://${GITLAB_HOST}"
ok "apps domain: ${APPS_DOMAIN}"
ok "GitLab will be at: ${GITLAB_URL}"

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
        -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" == "1" ]] && break
  printf '.'; sleep 10
done; echo
ARGO_HOST="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)"
ARGO_PW="$(oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || true)"
ok "ArgoCD ready: https://${ARGO_HOST}"

# ------------------------------------------------- 2 namespace + registry ---
log "2/9  App namespace, image-push service account"
oc apply -f "${REPO_DIR}/deploy/registry/01-namespace-and-pusher.yaml" >/dev/null
oc apply -f "${REPO_DIR}/deploy/registry/02-pusher-token.yaml" >/dev/null
oc create imagestream "$APP_NS" -n "$APP_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
  -p '{"spec":{"defaultRoute":true}}' >/dev/null 2>&1 || warn "could not enable registry default route"

printf '    waiting for pusher token'
PUSHER_TOKEN=""
for _ in $(seq 1 20); do
  PUSHER_TOKEN="$(oc get secret gitlab-pusher-token -n "$APP_NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$PUSHER_TOKEN" ]] && break
  printf '.'; sleep 3
done; echo
[[ -n "$PUSHER_TOKEN" ]] || die "pusher SA token was not populated"
ok "namespace ${APP_NS} + gitlab-pusher token ready"

# --------------------------------------------------------------- 3 GitLab ---
# NOTE: we install GitLab with Helm, not the GitLab operator. The only operator
# version in the catalogs (v3.2.0) bundles chart 10.x, which removed the
# in-cluster PostgreSQL/Redis/MinIO. Chart 9.11.x still bundles them.
log "3/9  GitLab namespace + Helm repo"
oc create namespace "$GITLAB_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
# GitLab's pods use fixed UIDs (65534 for the shared-secrets hook) AND set the
# legacy seccomp.security.alpha.kubernetes.io annotations. restricted-v2 rejects
# the UID; the built-in anyuid rejects the seccomp annotation. So we ship a custom
# SCC (anyuid + seccomp allowed) and bind it to this namespace's service accounts.
# The GitLab operator used to handle this; a plain Helm install does not.
oc apply -f "${REPO_DIR}/deploy/gitlab/00-scc-gitlab-anyuid.yaml" >/dev/null
oc adm policy add-scc-to-group gitlab-anyuid "system:serviceaccounts:${GITLAB_NS}" >/dev/null
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
ok "namespace ${GITLAB_NS} ready (anyuid granted), gitlab helm repo added"

log "4/9  Self-signed TLS for *.${APPS_DOMAIN}"
CERT_DIR="${OUT_DIR}/certs"; mkdir -p "$CERT_DIR"
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
ok "TLS + CA secrets created"

log "5/9  GitLab (Helm chart ${GITLAB_CHART_VERSION}) — this takes ~10-20 min"
sed -e "s|__APPS_DOMAIN__|${APPS_DOMAIN}|g" \
    "${REPO_DIR}/deploy/gitlab/02-gitlab-values.yaml" > "${OUT_DIR}/gitlab-values.rendered.yaml"
helm upgrade --install gitlab gitlab/gitlab \
  --version "$GITLAB_CHART_VERSION" -n "$GITLAB_NS" \
  -f "${OUT_DIR}/gitlab-values.rendered.yaml" \
  --timeout 15m >/dev/null
printf '    waiting for gitlab webservice'
for _ in $(seq 1 150); do
  [[ "$(oc get deploy -n "$GITLAB_NS" -l app=webservice \
        -o jsonpath='{.items[*].status.availableReplicas}' 2>/dev/null)" == *1* ]] && break
  printf '.'; sleep 12
done; echo
[[ "$(oc get deploy -n "$GITLAB_NS" -l app=webservice -o jsonpath='{.items[*].status.availableReplicas}' 2>/dev/null)" == *1* ]] \
  || die "GitLab webservice never became available (check: oc get pods -n ${GITLAB_NS})"
GITLAB_ROOT_PW="$(oc get secret gitlab-gitlab-initial-root-password -n "$GITLAB_NS" -o jsonpath='{.data.password}' | base64 -d)"
ok "GitLab up at ${GITLAB_URL} (root / ${GITLAB_ROOT_PW})"

# ------------------------------------------------------ 6 GitLab API prep ---
log "6/9  GitLab API token + runner registration"
TOOLBOX="$(oc get pod -n "$GITLAB_NS" -l app=toolbox -o name | head -1)"
[[ -n "$TOOLBOX" ]] || die "gitlab toolbox pod not found"
GITLAB_PAT="glpat-$(openssl rand -hex 10)"
oc exec -n "$GITLAB_NS" "$TOOLBOX" -c toolbox -- gitlab-rails runner "
u = User.find_by_username('root');
t = u.personal_access_tokens.create!(scopes: ['api','write_repository'], name: 'automation-$(date +%s)', expires_at: 365.days.from_now);
t.set_token('${GITLAB_PAT}'); t.save!;
" >/dev/null 2>&1 || die "failed to create GitLab root PAT"
ok "root PAT created"

gl_api() { curl -sk -H "PRIVATE-TOKEN: ${GITLAB_PAT}" "$@"; }

RUNNER_TOKEN="$(gl_api --request POST "${GITLAB_URL}/api/v4/user/runners" \
  --data "runner_type=instance_type" --data "description=ocp-kubernetes-runner" \
  --data "run_untagged=true" --data "tag_list=ocp,buildah" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
[[ -n "$RUNNER_TOKEN" ]] || die "failed to create GitLab runner"
ok "instance runner registered"

# --------------------------------------------------------------- 7 runner ---
log "7/9  GitLab Runner (privileged, for buildah)"
oc create namespace "$RUNNER_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create serviceaccount gitlab-runner-sa -n "$RUNNER_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc adm policy add-scc-to-user privileged -z gitlab-runner-sa -n "$RUNNER_NS" >/dev/null
# NOTE: chart 0.76 projects BOTH keys; runner-registration-token must exist (may be empty).
oc create secret generic gitlab-runner-secret -n "$RUNNER_NS" \
  --from-literal=runner-token="$RUNNER_TOKEN" \
  --from-literal=runner-registration-token="" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
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

# ------------------------------------------------- 8 GitLab project + vars ---
log "8/9  GitLab project + CI/CD variables"
PROJECT_ID="$(gl_api "${GITLAB_URL}/api/v4/projects?search=${GITLAB_PROJECT}&owned=true" \
  | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(gl_api --request POST "${GITLAB_URL}/api/v4/projects" \
    --data "name=${GITLAB_PROJECT}" --data "visibility=private" \
    | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
fi
[[ -n "$PROJECT_ID" ]] || die "failed to create/find GitLab project"
# Mirror force-pushes onto main, so it must not be protected.
gl_api --request DELETE "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/protected_branches/main" >/dev/null 2>&1 || true

set_var() { # key value
  gl_api --request POST "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables" \
    --data "key=$1" --data-urlencode "value=$2" --data "masked=false" --data "protected=false" >/dev/null 2>&1 \
  || gl_api --request PUT "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables/$1" \
    --data-urlencode "value=$2" --data "masked=false" --data "protected=false" >/dev/null 2>&1
}
set_var REGISTRY_USER  "gitlab-pusher"
set_var REGISTRY_TOKEN "$PUSHER_TOKEN"
set_var GITHUB_TOKEN   "$GH_PAT"
ok "project id ${PROJECT_ID}, CI variables set"

# seed the GitLab project so a pipeline can run before the first GitHub push
git -C "$REPO_DIR" -c http.sslVerify=false push --force \
  "https://oauth2:${GITLAB_PAT}@${GITLAB_HOST}/root/${GITLAB_PROJECT}.git" HEAD:main >/dev/null 2>&1 \
  && ok "seeded GitLab project with repo contents" \
  || warn "could not seed GitLab project (push it manually later)"

# ------------------------------------------------------- 9 GitHub + ArgoCD ---
log "9/9  GitHub secrets + ArgoCD Application"
if command -v gh >/dev/null; then
  GH_TOKEN="$GH_PAT" gh secret   set GITLAB_PUSH_TOKEN --body "$GITLAB_PAT"  --repo "$GITHUB_REPO" >/dev/null 2>&1 \
    && ok "GitHub secret GITLAB_PUSH_TOKEN set" || warn "could not set GitHub secret"
  GH_TOKEN="$GH_PAT" gh variable set GITLAB_URL --body "$GITLAB_HOST" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
    && ok "GitHub variable GITLAB_URL=${GITLAB_HOST}" || warn "could not set GitHub variable"
else
  warn "gh CLI not found — set GITLAB_PUSH_TOKEN (secret) and GITLAB_URL=${GITLAB_HOST} (variable) manually"
fi

oc apply -f "${REPO_DIR}/deploy/argocd/02-sample-app-application.yaml" >/dev/null
oc annotate application sample-app -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
ok "ArgoCD Application applied"

# GitHub -> ArgoCD push webhook, so a gitops commit syncs immediately instead of
# waiting out ArgoCD's 3-minute polling interval (timeout.reconciliation).
# insecure_ssl=1 because the route uses the cluster's self-signed router cert.
WEBHOOK_SECRET="$(openssl rand -hex 20)"
oc patch secret argocd-secret -n openshift-gitops --type merge \
  -p "{\"stringData\":{\"webhook.github.secret\":\"${WEBHOOK_SECRET}\"}}" >/dev/null 2>&1
oc rollout restart deploy/openshift-gitops-server -n openshift-gitops >/dev/null 2>&1
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=120s >/dev/null 2>&1
HOOK_URL="https://${ARGO_HOST}/api/webhook"
for id in $(curl -s -H "Authorization: token ${GH_PAT}" "https://api.github.com/repos/${GITHUB_REPO}/hooks" \
            | python3 -c "import sys,json;[print(h['id']) for h in json.load(sys.stdin) if h.get('config',{}).get('url','').endswith('/api/webhook')]" 2>/dev/null); do
  curl -s -X DELETE -H "Authorization: token ${GH_PAT}" \
    "https://api.github.com/repos/${GITHUB_REPO}/hooks/${id}" >/dev/null 2>&1
done
if curl -sf -X POST -H "Authorization: token ${GH_PAT}" \
     "https://api.github.com/repos/${GITHUB_REPO}/hooks" \
     -d "{\"name\":\"web\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"${HOOK_URL}\",\"content_type\":\"json\",\"secret\":\"${WEBHOOK_SECRET}\",\"insecure_ssl\":\"1\"}}" \
     >/dev/null 2>&1; then
  ok "GitHub -> ArgoCD webhook created (instant sync)"
else
  warn "could not create ArgoCD webhook — ArgoCD will still poll every 3 min"
fi

# --------------------------------------------------------------- summary ----
cat > "${OUT_DIR}/credentials.txt" <<EOF
# Generated $(date). KEEP THIS FILE - these cannot be recovered later.
CLUSTER_API=$(oc whoami --show-server)
APPS_DOMAIN=${APPS_DOMAIN}

ARGOCD_URL=https://${ARGO_HOST}
ARGOCD_USER=admin
ARGOCD_PASSWORD=${ARGO_PW}
ARGOCD_WEBHOOK_SECRET=${WEBHOOK_SECRET}

GITLAB_URL=${GITLAB_URL}
GITLAB_USER=root
GITLAB_PASSWORD=${GITLAB_ROOT_PW}
GITLAB_ROOT_PAT=${GITLAB_PAT}
GITLAB_PROJECT_ID=${PROJECT_ID}
GITLAB_RUNNER_TOKEN=${RUNNER_TOKEN}

APP_URL=https://sample-app-${APP_NS}.${APPS_DOMAIN}
EOF
chmod 600 "${OUT_DIR}/credentials.txt"

log "Done"
cat <<EOF
  ArgoCD    https://${ARGO_HOST}          admin / ${ARGO_PW}
  GitLab    ${GITLAB_URL}                 root / ${GITLAB_ROOT_PW}
  Pipelines ${GITLAB_URL}/root/${GITLAB_PROJECT}/-/pipelines
  App       https://sample-app-${APP_NS}.${APPS_DOMAIN}

  Credentials saved to: ${OUT_DIR}/credentials.txt

  Next: edit sample-app/app.py, commit and push to ${GITHUB_REPO}.
        The GitHub Action mirrors to GitLab -> pipeline builds -> ArgoCD deploys.
EOF
