# LogQL query samples

The sample application emits **JSON logs to stdout** with these fields:

```json
{
  "ts":      "2026-07-28T10:30:00.000Z",
  "level":   "INFO",
  "msg":     "request served path=/",
  "logger":  "sample-app",
  "app":     "sample-app",
  "env":     "sample-app-dev",       // matches the K8s namespace
  "version": "95b3d6a6",             // the commit SHA of the running image
  "pod":     "sample-app-675fffd897-xsp25"
}
```

The K8s pods carry these standard labels (added by kustomize):

- `app.kubernetes.io/name: sample-app`
- `app.kubernetes.io/part-of: cicd-demo`
- `app.kubernetes.io/instance: sample-app-dev` or `sample-app-prod`

Together they make good Loki queries trivial. Below assume the Loki datasource
is wired into OpenShift Console / Grafana in the standard way (OpenShift
Logging + LokiStack).


## 1 · All logs for the sample app, both environments

```logql
{ kubernetes_namespace_name=~"sample-app-(dev|prod)",
  kubernetes_labels_app_kubernetes_io_name="sample-app" }
```


## 2 · Everything a specific commit did in the last 24h

Useful for "what happened when we deployed X?" — the app's own `version` field
in the JSON log carries the commit SHA.

```logql
{ kubernetes_labels_app_kubernetes_io_name="sample-app" }
  | json
  | version = "95b3d6a6"
```


## 3 · Errors only, both envs, last hour

```logql
{ kubernetes_labels_app_kubernetes_io_name="sample-app" }
  | json
  | level = "ERROR"
```


## 4 · Request rate — dev vs prod (metric query)

```logql
sum by (env) (
  rate({ kubernetes_labels_app_kubernetes_io_name="sample-app" }
       | json
       | msg =~ "request served .*" [5m])
)
```


## 5 · Which pods served each version? (audit)

```logql
count by (pod, version) (
  { kubernetes_labels_app_kubernetes_io_name="sample-app" }
    | json
    | msg =~ "request served .*"
)
```


## 6 · Everything the GitLab Runner logged in the last hour

```logql
{ kubernetes_namespace_name="gitlab-runner",
  kubernetes_labels_app="gitlab-runner" }
```

Useful when a pipeline job "runs forever" — this shows what the manager saw.


## 7 · ArgoCD sync events

```logql
{ kubernetes_namespace_name="openshift-gitops",
  kubernetes_pod_name=~"openshift-gitops-application-controller-.*" }
  |= "sample-app-"
```


## Field-name caveat

The label promotion from Kubernetes to Loki depends on the collector's config.
This document uses the OpenShift Logging default — `kubernetes_namespace_name`,
`kubernetes_labels_app_kubernetes_io_name`, etc. Some clusters have a different
`labelKey` transform (`kubernetes.namespace_name`, or a stripped variant); adjust
the label names to match `oc explain lokistack.spec.limits.global.retention`
in the customer's env, or spot-check with a quick browse in the Console's
**Observe → Logs** panel.
