#!/usr/bin/env bash
#
# 02-install-istio.sh — instala o Istio OSS no cluster (sem ingress gateway).
#
# O teste de roteamento da plataforma é mesh-interno (client → candidata), então
# NÃO instalamos ingress/egress gateway — isso evita criar um Load Balancer (custo).
# Usamos o profile 'minimal' (apenas o istiod / control plane).
#
# Pré-requisitos:
#   - cluster criado e kubeconfig ativo (infra/01-create-cluster.md)
#   - istioctl instalado  (https://istio.io/latest/docs/setup/getting-started/#download)
#
# Uso:
#   ./02-install-istio.sh

set -euo pipefail

NAMESPACE="payments"

echo "────────────────────────────────────────────────────────────"
echo " Instalando Istio OSS (profile minimal, sem ingress gateway)"
echo "────────────────────────────────────────────────────────────"

# Confirma o contexto atual (evita instalar no cluster errado)
echo "Contexto kube atual:"
kubectl config current-context
echo

# 1. Control plane apenas (istiod); sem gateways.
istioctl install --set profile=minimal -y

# 2. Namespace da aplicação + habilitação da injeção automática de sidecar.
#    (apenas os clients recebem sidecar via annotation no chart; o label no
#     namespace garante que o webhook de injeção esteja ativo para eles.)
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite

echo
echo "────────────────────────────────────────────────────────────"
echo " Istio instalado. Verificação:"
echo "────────────────────────────────────────────────────────────"
kubectl get pods -n istio-system
echo
echo " Namespace '${NAMESPACE}' rotulado para injeção:"
kubectl get namespace "${NAMESPACE}" --show-labels
