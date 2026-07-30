# sample-app

Reference monorepo for the OpenShift CI/CD demo.

```
app/                     application source (Python + Flask + gunicorn on UBI 9)
gitops/                  Kustomize manifests
  base/                  Deployment, Service, Route (shared across environments)
  overlays/
    dev/                 auto-synced by ArgoCD
    prod/                manual-sync, MR-gated (higher replica count)
.gitlab-ci.yml           pipeline: buildah -> JFrog -> bump gitops/overlays/dev
```

## How to change the app

1. Edit `app/app.py`, commit + push to `main`.
2. Pipeline builds the image, tags it with the commit SHA, pushes to JFrog.
3. Pipeline commits a tag bump into `gitops/overlays/dev/kustomization.yaml`.
4. ArgoCD auto-syncs `sample-app-dev` within seconds.

## How to promote dev → prod

Open an MR that copies the current dev `newTag` into
`gitops/overlays/prod/kustomization.yaml`. Get it reviewed + approved,
merge. Then sync `sample-app-prod` in ArgoCD (UI or CLI).

Prod is deliberately not auto-synced — the MR is the audit line.
