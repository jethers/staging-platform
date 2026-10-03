#!/usr/bin/env bash
#
# 02-install-istio.sh — instala o Istio OSS no cluster (sem ingress gateway).
#
# O teste de roteamento da plataforma é mesh-interno (client → candidata), então
# NÃO instalamos ingress/egress gateway — isso evita criar um Load Balancer (custo).
# Usamos o profile 'minimal' (apenas o istiod / control plane).
#
# IMPORTANTE (GKE Autopilot): o Istio CNI node agent exige a capability SYS_ADMIN,
# que o Autopilot NÃO concede (nem com allow-net-admin). Por isso desabilitamos o
# CNI (components.cni.enabled=false) — o Istio usa então o init-container
# 'istio-init', que configura o iptables com o NET_ADMIN liberado pela flag
# allow-net-admin do cluster. Sem isso, a instalação falha ao tentar escrever um
# ConfigMap em kube-system (namespace gerenciado e bloqueado no Autopilot).
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

# 1. Control plane apenas (istiod); sem gateways; sem CNI (usa istio-init).
istioctl install --set profile=minimal --set components.cni.enabled=false -y

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
