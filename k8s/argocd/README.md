# Argo CD

`make gitops` installs Argo CD and creates one Application per chart: Qdrant, Ollama,
the Agent, and monitoring. Each watches `main`, syncs automatically, and prunes and
self-heals, so a change to a chart or its values reaches the cluster on its own and a
manual `kubectl edit` is undone.

The Applications pull over anonymous HTTPS, so the repository has to be public — which the
submission requires anyway. A private one needs a Secret in the `argocd` namespace labelled
`argocd.argoproj.io/secret-type: repository`, carrying the URL and an HTTPS token or SSH key. The
Applications themselves do not change.

Monitoring syncs with `ServerSideApply=true`, because the Prometheus CRDs are too
big for the apply annotation. Its three upstream charts are pinned to exact versions
in `k8s/observability/Chart.yaml`, so none of them can move without a commit.

The version is pinned in `Makefile` with `ARGOCD_VERSION`; override it for an
intentional upgrade, for example `make gitops ARGOCD_VERSION=v3.4.7`.

```sh
kubectl -n argocd get applications
```

## Releasing the Agent

Charts sync themselves, but a new image does not: Argo CD only reacts to a
commit. `make release` is that commit. It fetches `GITOPS_BRANCH` (`main`), adds
a detached worktree of it, builds and pushes `localhost:5001/agent:<commit>` from
there, writes the tag into `k8s/agent/values.yaml`, and pushes the one-file
commit back onto the branch.

The tag is the commit that last changed `app/`, so releasing an unchanged app
builds the same image and makes no commit. Because the work happens in a
worktree, `make release` releases `main` from any checkout, and `git revert` on
a release commit rolls the cluster back.

`make all` is `up release gitops`: the image and its tag reach GitHub before
Argo CD starts syncing.

`make deploy` still installs the charts with Helm directly, for the inner loop.
Argo CD pulls anything it changes back on the next sync.
