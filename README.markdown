# Accessing ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

# Bootstrapping a new cluster

## 1. Install ArgoCD

Follow the [ArgoCD installation docs](https://argo-cd.readthedocs.io/en/stable/getting_started/).

## 2. Restore the Sealed Secrets signing key

```bash
kubectl create namespace kube-system 2>/dev/null || true
kubectl apply -f sealed-secrets-key.yaml
```

This must be done before the root app is applied. Without the original key,
the sealed-secrets controller will generate a new key pair and won't be able
to decrypt the existing SealedSecret resources in this repo.

## 3. Apply the root application

```bash
kubectl apply -f clusters/pibox/argocd/root-app.yaml
```

This creates the `pi-root` app-of-apps, which syncs all applications from
`clusters/pibox/apps/`. Sealed-secrets and cert-manager deploy first
(sync-wave `-1`), then the remaining apps.

## Backing up the signing key

```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.yaml
```

Store this file securely outside the repository.
