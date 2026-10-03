#!/usr/bin/env bash
#
# simulate-change.sh — simula a janela de change (Job 2 do GitHub Actions, condensado).
#
# No fluxo real, o Job 2 executado na janela de change: lê o PR de promoção, valida os
# gates (change aprovada, janela, PR aprovado), revalida os testes de integração, dá
# merge no PR (que atualiza o repo de PRODUÇÃO com o novo digest), acompanha o rollout
# em produção e, com o rollout bem-sucedido, executa o promote (pós-deploy).
#
# Esta simulação condensa isso em dois passos, na ordem correta:
#   1) atualiza gitops-production/<service>/release.yaml com o novo digest
#      (representa o merge do PR de promoção)
#   2) executa o promote.py (pós-deploy): espelha o digest no runtime compartilhado
#      do staging e remove os efêmeros (candidate/ e */client/for-<service>/)
#
# Os passos de revalidação de testes e de acompanhamento do rollout ficam implícitos.
#
# Uso:
#   ./simulate-change.sh <service> <digest>
#
# Exemplo (promover a versão 2 do wallet):
#   ./simulate-change.sh wallet sha256:wallet-v2-prod
#
# Variáveis de ambiente (opcionais; têm default relativo a este script):
#   GITOPS_STAGING_PATH  path do repositório gitops-staging
#   GITOPS_PROD_PATH     path do repositório gitops-production

set -euo pipefail

SERVICE="${1:-}"
DIGEST="${2:-}"

if [[ -z "$SERVICE" || -z "$DIGEST" ]]; then
  echo "Uso: $0 <service> <digest>" >&2
  echo "Exemplo: $0 wallet sha256:wallet-v2-prod" >&2
  exit 1
fi

if [[ "$DIGEST" != sha256:* ]]; then
  echo "Digest inválido: '$DIGEST'. Deve começar com 'sha256:'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GITOPS_STAGING_PATH="${GITOPS_STAGING_PATH:-$REPO_ROOT/gitops-staging}"
export GITOPS_PROD_PATH="${GITOPS_PROD_PATH:-$REPO_ROOT/gitops-production}"

PROD_RELEASE="$GITOPS_PROD_PATH/$SERVICE/release.yaml"

echo "────────────────────────────────────────────────────────────"
echo " Janela de change (simulada)"
echo "   serviço promovido : $SERVICE"
echo "   digest produtivo  : $DIGEST"
echo "────────────────────────────────────────────────────────────"

# Passo 1 — merge do PR de promoção: atualiza o repo de PRODUÇÃO.
# Se este passo falhar, o script NÃO segue para o promote (o pós-deploy só faz
# sentido depois que produção foi efetivamente atualizada e o rollout ocorreu).
echo "[1/2] Atualizando o repo de produção (merge do PR de promoção)..."
if [[ ! -f "$PROD_RELEASE" ]]; then
  echo "  ✗ release.yaml de produção não encontrado: $PROD_RELEASE" >&2
  echo "  → promote abortado." >&2
  exit 1
fi

if ! printf '# Imagem promovida da homologação — atualizada pela automação após aprovação do PR\nimage:\n  digest: "%s"\n' "$DIGEST" > "$PROD_RELEASE"; then
  echo "  ✗ falha ao escrever o digest em $PROD_RELEASE" >&2
  echo "  → promote abortado." >&2
  exit 1
fi

# Confirma que o digest foi de fato gravado antes de prosseguir.
if ! grep -q "$DIGEST" "$PROD_RELEASE"; then
  echo "  ✗ o digest não foi gravado corretamente em $PROD_RELEASE" >&2
  echo "  → promote abortado." >&2
  exit 1
fi
echo "  ✓ produção atualizada: $PROD_RELEASE"

# Passo 2 — pós-deploy (rollout OK): espelha no staging compartilhado e limpa efêmeros.
# Só chega aqui se o passo 1 teve sucesso.
echo "[2/2] Executando o promote (pós-deploy)..."
python3 "$SCRIPT_DIR/promote.py" --service "$SERVICE" --digest "$DIGEST"
