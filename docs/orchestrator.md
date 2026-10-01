# Orquestrador de Homologação

O orquestrador prepara o ambiente de homologação no `gitops-staging`. São dois scripts no diretório `orchestrator/`, compartilhando os mesmos módulos auxiliares, acionados em momentos distintos do ciclo de vida:

- **`orchestrator.py`** — setup da candidata (acionado pelo CI quando uma candidata entra em homologação)
- **`promote.py`** — atualização e limpeza (acionado após o deploy em produção ser concluído — ver [pós-deploy](post-deploy.md))

Este documento descreve o `orchestrator.py` (setup).

## Responsabilidades do setup

1. Ler os manifestos de dependências e clients do serviço
2. Resolver os digests produtivos das dependências e clients
3. Escrever os `release.yaml` e os values no `gitops-staging`
4. Fazer commit e push — o Argo CD cuida do provisionamento

## Fluxo detalhado

```
Jenkins
  └── aciona GitHub Actions com:
        service=wallet
        digest=sha256:abc123...   (digest da imagem candidata, do CI)

GitHub Actions (orchestrator.py)
  1. Lê gitops-staging/wallet/dependencies.yaml   → ex.: [ledger]  (lista simples)
     Lê gitops-staging/wallet/clients.yaml        → ex.: [checkout]

  2. Valida o onboarding do wallet (values.yaml base + staging/ existem)

  3. Para cada dependência (compartilhada — ledger):
     └── valida que o ledger está onboardado (values.yaml base + staging/ existem)
     └── valida que ledger/staging/release.yaml tem digest preenchido (runtime ativo)
         (senão: erro acionável — não há runtime compartilhado para consumir)
     └── não provisiona nada dedicado (a candidata chama o ledger no host compartilhado)

  4. Para cada client (checkout):
     └── valida que o checkout está onboardado (values.yaml base + staging/ existem)
     └── gitops-production/checkout/release.yaml deve ter digest (senão: erro)
     └── cria a pasta checkout/client/for-wallet/:
           • values.yaml ← role: client, target: wallet, istioInject: true
           • release.yaml ← digest prod do checkout

  5. Cria/atualiza a candidata (idempotente):
     └── candidate/values.yaml ← role: candidate + lista de clients (para o VirtualService)
     └── candidate/release.yaml ← digest da candidata
         (rebuild na mesma homologação → sobrescreve só o release.yaml)

  6. Commit + push no gitops-staging

ApplicationSet + Argo CD
  └── gera as Applications e provisiona candidata e clients
  └── o VirtualService do host wallet é renderizado a partir dos values da candidata
      (rotas dos clients → wallet-candidate + fallback)

GitHub Actions (continuação da pipeline)
  7. Aguarda Argo CD reportar Synced/Healthy
  8. Executa testes de integração
  9. Testes OK → abre PR de promoção para produção
     Testes FAIL → notifica squad, preserva ambiente para investigação
```

## Entradas

| Parâmetro | Origem | Descrição | Exemplo |
|-----------|--------|-----------|---------|
| `service` | Jenkins (`--service` ou env `SERVICE`) | Nome do serviço sendo homologado | `wallet` |
| `digest` | Jenkins (`--digest` ou env `DIGEST`) | Digest SHA-256 da imagem candidata | `sha256:abc123...` |
| `GITOPS_STAGING_PATH` | env (infra) | Path do repositório gitops-staging | — |
| `GITOPS_PROD_PATH` | env (infra) | Path do repositório gitops-production | — |

O **namespace não é entrada** — é lido do campo `namespace` no `values.yaml` base de cada serviço, já que cada serviço pode estar num namespace diferente. O Jenkins fornece apenas `service` e `digest`.

## Regras de negócio

- **Setup idempotente da candidata** — a pasta `candidate/` é criada pelo orquestrador se ausente; se já existe (rebuild da imagem na mesma homologação), apenas o `release.yaml` é sobrescrito com o novo digest. O Git só gera commit se o arquivo mudar, então reaplicar com o mesmo digest não causa efeito. A pasta `candidate/` não faz parte do onboarding (é efêmera).
- **Onboarding é pré-requisito** — todo serviço envolvido (candidata, dependência, client) precisa estar onboardado: ter o `values.yaml` base **e** a pasta `staging/`. O orquestrador verifica a existência; se faltar, erro "serviço não onboardado". O orquestrador **não cria** `values.yaml` base nem `staging/` — só cria as pastas `candidate/` e `client/for-<candidate>/` durante o setup (ver decisões 18 e 20).
- **Dependências são compartilhadas (MVP)** — o orquestrador não provisiona nada dedicado para as dependências. Valida que cada dependência está onboardada e que seu `staging/release.yaml` tem **digest preenchido** (runtime ativo que a candidata vai consumir); se vazio, erro acionável orientando a preencher o digest compartilhado.
- **Client sem digest produtivo** — se `gitops-production/<client>/release.yaml` não existir ou tiver digest vazio, erro explícito.
- **Digests imutáveis** — sempre digest SHA-256, nunca tags mutáveis como `latest`.

## Dependências compartilhadas (MVP)

No MVP, todas as dependências são compartilhadas (ver decisão 19). O orquestrador, para cada dependência listada no `dependencies.yaml`:

- Valida que a dependência está onboardada (`values.yaml` base + `staging/`)
- Valida que o `staging/release.yaml` da dependência tem **digest preenchido** (runtime ativo) — a candidata vai consumir esse runtime compartilhado; se vazio, erro acionável
- **Não provisiona nada dedicado** — a candidata chama a dependência no host compartilhado (chamada direta, sem desvio Istio)

Dependências dedicadas ficam para evolução futura (ver decisão 19).

## Onboarding é pré-requisito; o orquestrador não cria staging

Qualquer serviço usado (candidata, dependência, client) precisa estar onboardado: ter o `values.yaml` base (`<service>/values.yaml`) **e** a pasta `staging/` (com `values.yaml` role: staging e `release.yaml`). O orquestrador verifica apenas a **existência** desses arquivos — se ausentes, erro "serviço não onboardado". Campos faltantes são pegos pelo Helm na renderização.

O orquestrador **não cria** a estrutura de staging de nenhum serviço — isso mantém o orquestrador simples e evita que ele escreva em serviços que não são o alvo da homologação. Ele só escreve nos arquivos da própria homologação: a pasta `candidate/` e as pastas `client/for-<candidate>/`. Ver [Argo CD e ApplicationSet](argocd.md), item "Service compartilhado garantido pelo onboarding", e decisão 18.

## Configuração do VirtualService (rotas)

O VirtualService do host da candidata é gerado pelo chart da pasta `candidate/`, a partir da lista de clients que o orquestrador escreve no `candidate/values.yaml` (lida do `clients.yaml`). É um único VirtualService com as rotas client → candidata + fallback. Como há uma candidata por serviço (decisão 2), não há merge entre recursos nem escrita concorrente. Ver [roteamento](routing.md) e decisão 14.

## Simulação local (PoC)

Na PoC, o Jenkins é simulado por um script shell que passa `service` e `digest` ao orquestrador. O orquestrador opera sobre os arquivos locais do repositório, sem precisar de cluster — a validação é feita renderizando os charts com `helm template`.
