#!/usr/bin/env bash
#
# simulate-ci.sh — simula a Pipeline de CI acionando o orquestrador de homologação.
#
# FRONTEIRA DE ESCOPO: o build, o scan e a publicação da imagem candidata, bem como
# o acionamento do CD, são responsabilidade da Pipeline de CI do serviço — FORA do
# escopo deste projeto. Espera-se apenas que, ao final do CI, a pipeline acione o CD
# (este orquestrador) passando o nome do serviço e o digest da imagem já publicada.
#
# Este script reproduz localmente esse acionamento, chamando o orchestrator.py.
#
# Uso:
#   ./simulate-ci.sh <service> <digest>
#
# Exemplo (homologar a versão 2 do wallet):
#   ./simulate-ci.sh wallet sha256:wallet-v2-candidate
#
# Variáveis de ambiente (opcionais; têm defaults relativos a este script):
#   GITOPS_STAGING_PATH  path do repositório gitops-staging
#   GITOPS_PROD_PATH     path do repositório gitops-production

set -euo pipefail

SERVICE="${1:-}"
DIGEST="${2:-}"

if [[ -z "$SERVICE" || -z "$DIGEST" ]]; then
  echo "Uso: $0 <service> <digest>" >&2
  echo "Exemplo: $0 wallet sha256:1fc69a...<digest da candidata>" >&2
  exit 1
fi

# Resolve paths relativos à raiz do repositório (um nível acima de orchestrator/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GITOPS_STAGING_PATH="${GITOPS_STAGING_PATH:-$REPO_ROOT/gitops-staging}"
export GITOPS_PROD_PATH="${GITOPS_PROD_PATH:-$REPO_ROOT/gitops-production}"

echo "────────────────────────────────────────────────────────────"
echo " Pipeline de CI (simulada)"
echo "   build/scan/push da imagem (externo ao projeto): $SERVICE"
echo "   digest publicado no registry                  : $DIGEST"
echo "   CI aciona o CD (orquestrador de homologação)..."
echo "────────────────────────────────────────────────────────────"

python3 "$REPO_ROOT/orchestrator/orchestrator.py" --service "$SERVICE" --digest "$DIGEST"
