#!/usr/bin/env bash
#
# setup-gitops.sh — prepara o estado base do gitops para a demo.
#
# Num cenário real, os digests produtivos chegam dos deploys em produção (docker push
# + promote). Para a demo, usamos valores fictícios e deterministas, e escrevemos o
# MESMO digest em produção e no staging compartilhado de cada serviço — ou seja, o
# runtime compartilhado de homologação espelha a produção vigente.
#
# Isso satisfaz os pré-requisitos do orquestrador:
#   - dependências (ex: ledger) com runtime compartilhado ativo no staging
#   - clients (ex: checkout) com digest produtivo registrado em produção
#
# Uso:
#   ./setup-gitops.sh
#
# Variáveis de ambiente (opcionais; têm defaults relativos a este script):
#   GITOPS_STAGING_PATH  path do repositório gitops-staging
#   GITOPS_PROD_PATH     path do repositório gitops-production

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GITOPS_STAGING_PATH="${GITOPS_STAGING_PATH:-$REPO_ROOT/gitops-staging}"
GITOPS_PROD_PATH="${GITOPS_PROD_PATH:-$REPO_ROOT/gitops-production}"

# Digests produtivos fictícios (determinísticos para a demo)
declare -A PROD_DIGESTS=(
  [wallet]="sha256:wallet-prod-v1"
  [ledger]="sha256:ledger-prod-v1"
  [checkout]="sha256:checkout-prod-v1"
)

echo "────────────────────────────────────────────────────────────"
echo " Setup do gitops (estado base da demo)"
echo "   gitops-staging    : $GITOPS_STAGING_PATH"
echo "   gitops-production : $GITOPS_PROD_PATH"
echo "────────────────────────────────────────────────────────────"

for svc in "${!PROD_DIGESTS[@]}"; do
  digest="${PROD_DIGESTS[$svc]}"

  prod_release="$GITOPS_PROD_PATH/$svc/release.yaml"
  staging_release="$GITOPS_STAGING_PATH/$svc/staging/release.yaml"

  # Produção: digest produtivo vigente
  printf '# Imagem promovida da homologação — atualizada pela automação após aprovação do PR\nimage:\n  digest: "%s"\n' "$digest" > "$prod_release"

  # Staging compartilhado: espelha a produção (mesmo digest = runtime ativo)
  printf '# Imagem da versão produtiva vigente — atualizada após cada deploy em produção\nimage:\n  digest: "%s"\n' "$digest" > "$staging_release"

  echo "  ✓ $svc → produção e staging com digest $digest"
done

echo "────────────────────────────────────────────────────────────"
echo " Estado base pronto. Os 3 serviços têm runtime compartilhado ativo"
echo " e digest produtivo registrado."
echo "────────────────────────────────────────────────────────────"
