# Argo CD

The local cluster can manage all three Helm charts from Git with:

```sh
make gitops
```

This installs Argo CD from its upstream manifest and creates applications for
Qdrant, Ollama, and the Agent. Each application watches the `main` branch and
enables automated sync, pruning, and drift correction.

The installed version is pinned in `Makefile` with `ARGOCD_VERSION`; override
it for an intentional upgrade, for example `make gitops ARGOCD_VERSION=v3.4.7`.

Changes must be merged and pushed to `main` before Argo CD can sync them:

```sh
git push origin main
```

## Releasing the Agent

`IMAGE_TAG` is `git log -1 --format=%h -- app`: the commit that last changed the
image's only input, `app/`. Argo CD redeploys the Agent when that tag changes in
`k8s/agent/values.yaml`, and `make release` is what changes it:

```sh
make release
```

It builds and pushes the image, writes the tag into `values.yaml`, and commits
and pushes that one file. Argo CD picks up the commit and rolls the Deployment
onto the new image; `git revert` on the release commit rolls it back. Releasing
again without touching `app/` leaves the tag where it is and makes no commit.

`make all` is `up release gitops`, in that order: the image and its tag reach
GitHub before Argo CD starts syncing, so the Agent comes up on the right image
the first time. It pushes to the remote, and it refuses to run with uncommitted
changes. Run it on `main`, the branch the applications track.

`make deploy` still installs the three charts with Helm directly, for the inner
loop. It bypasses Argo CD, which pulls the Deployment back to the released tag
on its next sync, so use it on a cluster without Argo CD installed.

To inspect sync state:

```sh
kubectl -n argocd get applications
```
