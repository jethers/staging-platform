#!/usr/bin/env bash
#
# setup-gitops.sh — prepara o estado base do gitops para a demo.
#
# Num cenário real, os digests produtivos chegam dos deploys em produção (docker push
# + promote). Para a demo, usamos os digests REAIS das imagens v1.0.0 publicadas no
# Artifact Registry, e escrevemos o MESMO digest em produção e no staging compartilhado
# de cada serviço — ou seja, o runtime compartilhado de homologação espelha a produção
# vigente. (A candidata do wallet usa a v2.0.0, digest sha256:1fc69a...)
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

# Digests reais das imagens v1.0.0 publicadas no Artifact Registry (produção vigente)
declare -A PROD_DIGESTS=(
  [wallet]="sha256:2e2a9b1db24d158b85bdb1a3a8a8d196017240a3d4436d27982da0662ed5ae79"
  [ledger]="sha256:e966d211ddc0c084b23fe69caf6663d6e46bcaabc31ad229c8498881b97f5c02"
  [checkout]="sha256:c377e7c566922b44291a3d5f7da1f17106f2562fe5bd1b0fafc7739720d81ba0"
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
