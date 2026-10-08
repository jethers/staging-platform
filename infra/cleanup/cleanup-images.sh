#!/usr/bin/env bash
#
# cleanup-images.sh — remove as imagens da PoC do Artifact Registry.
#
# Por padrão, apaga o repositório 'docker-images' inteiro (todas as imagens e tags).
# Operação IRREVERSÍVEL — mas reversível na prática: basta rodar
# infra/publish-images.sh para republicar a partir das imagens locais.
#
# Uso:
#   ./cleanup-images.sh            # pede confirmação
#   ./cleanup-images.sh --yes      # sem confirmação (CI)

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_GCP_PROJECT}"
LOCATION="${LOCATION:-us-central1}"
REPO="${REPO:-docker-images}"

AUTO_YES="${1:-}"

echo "────────────────────────────────────────────────────────────"
echo " LIMPEZA — imagens do Artifact Registry"
echo "   projeto : ${PROJECT_ID}"
echo "   região  : ${LOCATION}"
echo "   repo    : ${REPO}"
echo "────────────────────────────────────────────────────────────"

if ! gcloud artifacts repositories describe "${REPO}" \
      --location="${LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Repositório '${REPO}' não encontrado. Nada a fazer."
  exit 0
fi

if [[ "${AUTO_YES}" != "--yes" ]]; then
  read -r -p "Apagar o repositório '${REPO}' e todas as imagens? Digite 'sim': " ans
  [[ "${ans}" == "sim" ]] || { echo "Cancelado."; exit 1; }
fi

gcloud artifacts repositories delete "${REPO}" \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --quiet

echo "✓ Repositório '${REPO}' removido."
echo "  (para republicar: ./infra/publish-images.sh — ele recria o repo)"
