#!/usr/bin/env bash
#
# cleanup-cluster.sh — destrói o cluster GKE Autopilot da PoC.
#
# Remove o cluster inteiro (control plane + workloads + qualquer Load Balancer/
# disco que os workloads tenham criado). Operação IRREVERSÍVEL.
#
# Uso:
#   ./cleanup-cluster.sh            # pede confirmação
#   ./cleanup-cluster.sh --yes      # sem confirmação (CI)

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_GCP_PROJECT}"
LOCATION="${LOCATION:-us-central1}"
CLUSTER="${CLUSTER:-staging-platform}"

AUTO_YES="${1:-}"

echo "────────────────────────────────────────────────────────────"
echo " LIMPEZA — cluster GKE"
echo "   projeto : ${PROJECT_ID}"
echo "   região  : ${LOCATION}"
echo "   cluster : ${CLUSTER}"
echo "────────────────────────────────────────────────────────────"

if ! gcloud container clusters describe "${CLUSTER}" \
      --location="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Cluster '${CLUSTER}' não encontrado. Nada a fazer."
  exit 0
fi

if [[ "${AUTO_YES}" != "--yes" ]]; then
  read -r -p "Destruir o cluster '${CLUSTER}'? Digite 'sim' para confirmar: " ans
  [[ "${ans}" == "sim" ]] || { echo "Cancelado."; exit 1; }
fi

gcloud container clusters delete "${CLUSTER}" \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --quiet

echo "✓ Cluster '${CLUSTER}' removido."
echo
echo "Dica: confirme que não ficou Load Balancer/IP órfão:"
echo "  gcloud compute forwarding-rules list --project=${PROJECT_ID}"
echo "  gcloud compute addresses list --project=${PROJECT_ID}"
