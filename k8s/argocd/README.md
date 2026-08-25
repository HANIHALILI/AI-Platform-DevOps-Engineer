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

The image tag is `git log -1 --format=%h -- app`: the commit that last changed
the image's only input, `app/`. Argo CD redeploys the Agent when that tag changes
in `k8s/agent/values.yaml`, and `make release` is what changes it:

```sh
make release
```

It ignores the checkout entirely. It fetches `GITOPS_BRANCH` — `main` by default,
the branch the applications track — adds a detached worktree of it under `/tmp`,
builds and pushes the image from there, writes the tag into that worktree's
`values.yaml`, and commits and pushes the one file back onto the branch. The
worktree is removed on the way out. Running it from a feature branch releases
`main`, not the branch: the release is always what Argo CD is about to sync.

Argo CD picks up the commit and rolls the Deployment onto the new image; `git
revert` on the release commit rolls it back. A release that finds `app/`
unchanged pushes the same image and makes no commit.

`make all` is `up release gitops`, in that order: the image and its tag reach
GitHub before Argo CD starts syncing, so the Agent comes up on the right image
the first time.

`make deploy` still installs the three charts with Helm directly, for the inner
loop. It bypasses Argo CD, which pulls the Deployment back to the released tag
on its next sync, so use it on a cluster without Argo CD installed.

To inspect sync state:

```sh
kubectl -n argocd get applications
```
