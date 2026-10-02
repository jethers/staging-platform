#!/usr/bin/env bash
#
# simulate-change.sh — simula a janela de change acionando o promote (pós-deploy).
#
# No fluxo real, isto é o passo final do Job 2 do GitHub Actions, executado na janela
# de change aprovada: após ler o PR de promoção, validar os gates (change aprovada,
# janela, PR aprovado), revalidar os testes de integração, dar merge no PR e acompanhar
# o rollout em produção, o job chama o promote.py com o serviço e o digest produtivo.
#
# Este script reproduz apenas esse passo final (promote.py). Os passos anteriores do
# Job 2 estão fora do escopo da simulação local.
#
# Uso:
#   ./simulate-change.sh <service> <digest>
#
# Exemplo (promover a versão 2 do wallet):
#   ./simulate-change.sh wallet sha256:wallet-v2-prod
#
# Variáveis de ambiente (opcionais; têm default relativo a este script):
#   GITOPS_STAGING_PATH  path do repositório gitops-staging

set -euo pipefail

SERVICE="${1:-}"
DIGEST="${2:-}"

if [[ -z "$SERVICE" || -z "$DIGEST" ]]; then
  echo "Uso: $0 <service> <digest>" >&2
  echo "Exemplo: $0 wallet sha256:wallet-v2-prod" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GITOPS_STAGING_PATH="${GITOPS_STAGING_PATH:-$REPO_ROOT/gitops-staging}"

echo "────────────────────────────────────────────────────────────"
echo " Janela de change (simulada)"
echo "   serviço promovido : $SERVICE"
echo "   digest produtivo  : $DIGEST"
echo "   executando o passo final do Job 2 (promote.py)..."
echo "────────────────────────────────────────────────────────────"

python3 "$SCRIPT_DIR/promote.py" --service "$SERVICE" --digest "$DIGEST"
