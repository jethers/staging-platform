#!/usr/bin/env bash
#
# cleanup-all.sh — limpeza completa da PoC na GCP.
#
# Destrói, em ordem:
#   1. o cluster GKE Autopilot (e tudo que roda nele)
#   2. as imagens do Artifact Registry
#
# NÃO remove o projeto GCP nem a deploy key do GitHub (passos manuais, abaixo).
#
# Uso:
#   ./cleanup-all.sh            # pede confirmação em cada etapa
#   ./cleanup-all.sh --yes      # sem confirmação

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_YES="${1:-}"

# Project id vem do ambiente (os sub-scripts fazem o mesmo). Usado só nos lembretes abaixo.
PROJECT_ID="${PROJECT_ID:-YOUR_GCP_PROJECT}"

echo "════════════════════════════════════════════════════════════"
echo " LIMPEZA COMPLETA DA POC (GCP)"
echo "════════════════════════════════════════════════════════════"

"${SCRIPT_DIR}/cleanup-cluster.sh" "${AUTO_YES}"
echo
"${SCRIPT_DIR}/cleanup-images.sh" "${AUTO_YES}"

echo
echo "════════════════════════════════════════════════════════════"
echo " Limpeza automática concluída."
echo "════════════════════════════════════════════════════════════"
echo " Passos manuais que NÃO são destruídos por este script:"
echo "   • Deploy key no GitHub (repo → Settings → Deploy keys → remover 'argocd')"
echo "   • Chave SSH local: rm ~/.ssh/argocd_staging_platform{,.pub}"
echo "   • Projeto GCP (se quiser zerar tudo):"
echo "       gcloud projects delete ${PROJECT_ID}"
echo
echo " Conferir resíduos de rede (devem estar vazios):"
echo "   gcloud compute forwarding-rules list --project=${PROJECT_ID}"
echo "   gcloud compute addresses list --project=${PROJECT_ID}"
echo "   gcloud compute disks list --project=${PROJECT_ID}"
