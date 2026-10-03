#!/usr/bin/env bash
#
# simulate-jenkins.sh — simula o Jenkins acionando o orquestrador de homologação.
#
# No fluxo real, o Jenkins builda a imagem do serviço, publica no registry e aciona
# o GitHub Actions (orquestrador) passando o nome do serviço e o digest da imagem.
# Este script reproduz esse acionamento localmente, chamando o orchestrator.py.
#
# Uso:
#   ./simulate-jenkins.sh <service> <digest>
#
# Exemplo (homologar a versão 2 do wallet):
#   ./simulate-jenkins.sh wallet sha256:wallet-v2-candidate
#
# Variáveis de ambiente (opcionais; têm defaults relativos a este script):
#   GITOPS_STAGING_PATH  path do repositório gitops-staging
#   GITOPS_PROD_PATH     path do repositório gitops-production

set -euo pipefail

SERVICE="${1:-}"
DIGEST="${2:-}"

if [[ -z "$SERVICE" || -z "$DIGEST" ]]; then
  echo "Uso: $0 <service> <digest>" >&2
  echo "Exemplo: $0 wallet sha256:wallet-v2-candidate" >&2
  exit 1
fi

# Resolve paths relativos à raiz do repositório (um nível acima de orchestrator/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GITOPS_STAGING_PATH="${GITOPS_STAGING_PATH:-$REPO_ROOT/gitops-staging}"
export GITOPS_PROD_PATH="${GITOPS_PROD_PATH:-$REPO_ROOT/gitops-production}"

echo "────────────────────────────────────────────────────────────"
echo " Jenkins (simulado)"
echo "   build da imagem concluído para: $SERVICE"
echo "   digest publicado no registry  : $DIGEST"
echo "   acionando o orquestrador de homologação..."
echo "────────────────────────────────────────────────────────────"

python3 "$REPO_ROOT/orchestrator/orchestrator.py" --service "$SERVICE" --digest "$DIGEST"
