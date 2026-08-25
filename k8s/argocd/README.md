# Argo CD

The local cluster can manage all three Helm charts from Git with:

```sh
make gitops
```

This installs Argo CD from its upstream manifest and creates applications for
Qdrant, Ollama, and the Agent. Each application watches the
`feat/gitops-argocd` branch and enables automated sync, pruning, and drift
correction.

The branch must be pushed to GitHub before Argo CD can sync it:

```sh
git push -u origin feat/gitops-argocd
```

To inspect sync state:

```sh
kubectl -n argocd get applications
```