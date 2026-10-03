#!/usr/bin/env bash
#
# build-images.sh — builda as imagens dos serviços localmente.
#
# Cada serviço tem um Dockerfile multi-stage que injeta a versão no binário via
# ldflags (ARG VERSION). A versão aparece nos logs e nas respostas HTTP (campo
# "version"), o que permite distinguir, em runtime, a candidata do runtime
# compartilhado — essencial para provar o roteamento Istio.
#
# Imagens buildadas:
#   staging-platform/ledger:v1.0.0     (version=v1.0.0)
#   staging-platform/wallet:v1.0.0     (version=v1.0.0)
#   staging-platform/wallet:v2.0.0     (version=v2.0.0-candidate)  ← a candidata
#   staging-platform/checkout:v1.0.0   (version=v1.0.0)
#
# Pré-requisito do publish-images.sh (que tagueia e dá push dessas imagens).
#
# Uso:
#   ./build-images.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICES_DIR="$REPO_ROOT/services"

# Entradas: "<contexto>|<tag>|<VERSION>"
BUILDS=(
  "ledger|staging-platform/ledger:v1.0.0|v1.0.0"
  "wallet|staging-platform/wallet:v1.0.0|v1.0.0"
  "wallet|staging-platform/wallet:v2.0.0|v2.0.0-candidate"
  "checkout|staging-platform/checkout:v1.0.0|v1.0.0"
)

echo "════════════════════════════════════════════════════════════"
echo " Build das imagens dos serviços"
echo "════════════════════════════════════════════════════════════"

for entry in "${BUILDS[@]}"; do
  IFS='|' read -r svc tag version <<< "$entry"
  ctx="$SERVICES_DIR/$svc"

  echo "──────────────────────────────────────────────"
  echo " $tag  (VERSION=$version)"
  echo "   contexto: $ctx"

  docker build --build-arg VERSION="$version" -t "$tag" "$ctx"
done

echo
echo "════════════════════════════════════════════════════════════"
echo " Imagens buildadas:"
echo "════════════════════════════════════════════════════════════"
docker images --filter=reference='staging-platform/*' \
  --format '  {{.Repository}}:{{.Tag}}  {{.ID}}'
echo
echo " Próximo passo: ./infra/publish-images.sh (push para o Artifact Registry)"
