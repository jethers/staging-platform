#!/usr/bin/env bash
#
# 04-install-argocd.sh — instala o Argo CD no cluster.
#
# Pré-requisitos:
#   - cluster criado e kubeconfig ativo
#   - Istio instalado (passo 02)
#
# Uso:
#   ./04-install-argocd.sh
#
# Após instalar, cadastre a deploy key (infra/03-deploy-key.md, passo 3) e
# aplique o ApplicationSet (infra/argocd/applicationset.yaml).

set -euo pipefail

echo "────────────────────────────────────────────────────────────"
echo " Instalando Argo CD"
echo "────────────────────────────────────────────────────────────"
kubectl config current-context
echo

# 1. Namespace e instalação oficial.
#    --server-side é necessário: o CRD do ApplicationSet excede o limite de
#    annotation do apply client-side (metadata.annotations Too long).
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo
echo "Aguardando o argocd-server ficar pronto..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd

echo
echo "────────────────────────────────────────────────────────────"
echo " Argo CD instalado."
echo "────────────────────────────────────────────────────────────"
echo " Senha inicial do admin:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
echo
echo " Acesso à UI (port-forward):"
echo "   kubectl port-forward -n argocd svc/argocd-server 8080:443"
echo "   depois abra https://localhost:8080  (usuário: admin)"
echo
echo " Próximos passos:"
echo "   1. Cadastrar a deploy key (infra/03-deploy-key.md, passo 3)"
echo "   2. Aplicar o ApplicationSet: kubectl apply -f infra/argocd/applicationset.yaml"
