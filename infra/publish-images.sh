#!/usr/bin/env bash
#
# publish-images.sh — publica as imagens dos serviços no Artifact Registry do GCP
# e captura os digests reais (os que vão nos release.yaml do gitops).
#
# Pré-requisitos:
#   - gcloud instalado e autenticado (gcloud auth login)
#   - as imagens locais já buildadas:
#       staging-platform/ledger:v1.0.0
#       staging-platform/wallet:v1.0.0
#       staging-platform/wallet:v2.0.0   (candidata)
#       staging-platform/checkout:v1.0.0
#
# Uso:
#   ./publish-images.sh
#
# O digest que vale para o GitOps é o que o Artifact Registry retorna no push
# (não o digest local). Este script captura e imprime esse valor ao final.

set -euo pipefail

PROJECT_ID="staging-platform-510420"
REGION="us-central1"
REPO="docker-images"
REGISTRY="${REGION}-docker.pkg.dev"
BASE="${REGISTRY}/${PROJECT_ID}/${REPO}"

# Mapa: <imagem local> → <nome:tag no registry>
IMAGES=(
  "staging-platform/ledger:v1.0.0|ledger:v1.0.0"
  "staging-platform/wallet:v1.0.0|wallet:v1.0.0"
  "staging-platform/wallet:v2.0.0|wallet:v2.0.0"
  "staging-platform/checkout:v1.0.0|checkout:v1.0.0"
)

echo "════════════════════════════════════════════════════════════"
echo " Publicação de imagens no Artifact Registry"
echo "   projeto  : ${PROJECT_ID}"
echo "   região   : ${REGION}"
echo "   repo     : ${REPO}"
echo "   registry : ${BASE}"
echo "════════════════════════════════════════════════════════════"

# 1. Define o projeto ativo
echo "[1/4] Configurando projeto ativo..."
gcloud config set project "${PROJECT_ID}" >/dev/null

# 2. Garante que a API do Artifact Registry está habilitada
echo "[2/4] Habilitando a API do Artifact Registry (se necessário)..."
gcloud services enable artifactregistry.googleapis.com >/dev/null

# 3. Cria o repositório Docker (idempotente) e configura o docker auth
echo "[3/4] Garantindo o repositório '${REPO}' e o auth do Docker..."
if ! gcloud artifacts repositories describe "${REPO}" --location="${REGION}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Imagens dos serviços da plataforma de homologação"
  echo "  ✓ repositório '${REPO}' criado"
else
  echo "  ✓ repositório '${REPO}' já existe"
fi
gcloud auth configure-docker "${REGISTRY}" --quiet

# 4. Retag + push de cada imagem; captura o digest confirmado pelo registry
echo "[4/4] Publicando imagens e capturando digests..."
echo
declare -a RESULTS=()
for entry in "${IMAGES[@]}"; do
  local_img="${entry%%|*}"
  remote_tag="${entry##*|}"
  remote_img="${BASE}/${remote_tag}"

  echo "──────────────────────────────────────────────"
  echo " ${local_img}"
  echo "   → ${remote_img}"

  docker tag "${local_img}" "${remote_img}"
  docker push "${remote_img}"

  # Digest confirmado pelo Artifact Registry (fonte da verdade para o gitops)
  digest="$(gcloud artifacts docker images describe "${remote_img}" \
    --format='value(image_summary.digest)')"

  RESULTS+=("${remote_tag}|${digest}")
  echo "   digest: ${digest}"
done

echo
echo "════════════════════════════════════════════════════════════"
echo " Digests publicados (use nos release.yaml do gitops):"
echo "════════════════════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do
  tag="${r%%|*}"
  digest="${r##*|}"
  printf "  %-20s %s\n" "${tag}" "${digest}"
done
echo
echo " Referência completa de pull: ${BASE}/<serviço>@<digest>"
echo "════════════════════════════════════════════════════════════"
