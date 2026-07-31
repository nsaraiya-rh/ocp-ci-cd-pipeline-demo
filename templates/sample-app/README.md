# sample-app

Reference monorepo for the OpenShift CI/CD demo. **Branches are environments:**
the `dev` branch drives the dev environment, `main` drives prod.

```
app/                     application source (Python + Flask + gunicorn on UBI 9)
gitops/                  Kustomize manifests
  base/                  Deployment, Service, Route (shared across environments)
  overlays/
    dev/                 image tag bumped on the `dev` branch; ArgoCD auto-syncs
    prod/                image tag bumped on `main` (promote); manual-sync, 3 replicas
.gitlab-ci.yml           dev branch: build -> JFrog -> bump overlays/dev
                         main branch (on merge): promote dev's tag into overlays/prod
```

## How to ship a change (dev)

1. On the **`dev` branch**, edit `app/app.py`, commit + push.
2. `build-image` builds the image, tags it `<commit sha>`, pushes to JFrog.
3. `deploy-dev` bumps `gitops/overlays/dev/kustomization.yaml` on the `dev` branch.
4. ArgoCD (tracking `dev`) auto-syncs `sample-app-dev` within seconds.

## How to promote dev → prod

1. Open a **merge request `dev` → `main`**.
2. Get it approved and merge — **leave "Delete source branch" unchecked** (the
   `dev` branch is permanent). The `promote-prod` job copies dev's current image
   tag into `gitops/overlays/prod/kustomization.yaml` on `main` — **no rebuild**,
   the exact image dev ran.
3. Open `sample-app-prod` in ArgoCD and click **Sync**.

Prod is deliberately not auto-synced — the MR is one audit line, the Sync click
is the other.
