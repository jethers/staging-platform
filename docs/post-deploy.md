# Processo pós-deploy: atualização e limpeza da homologação

Após uma candidata ser promovida e deployada em produção, dois processos distintos ocorrem no `gitops-staging`, executados pelo script `promote.py` (separado do `orchestrator.py` de setup, pois ocorrem em momentos diferentes do ciclo de vida).

Ambos reagem a um deploy em produção e recebem como entrada o **nome do serviço promovido** e o **novo digest produtivo**.

> **Ordem no ciclo de change:** o `promote.py` é o **passo pós-deploy**. Antes dele, o repo de **produção** (`gitops-production/<service>/release.yaml`) já foi atualizado com o novo digest (o merge do PR de promoção) e o rollout em produção concluiu. Só então o `promote.py` espelha o digest no staging compartilhado e limpa os efêmeros. Na demo, o `scripts/simulate-change.sh` encadeia os dois passos (atualiza produção → roda o `promote.py`), abortando se a atualização de produção falhar.

## Princípio: homologação sempre reflete a produção atual

O ambiente de homologação deve espelhar continuamente a realidade de produção. Quando um serviço muda em produção, **todas as candidatas que dependem dele são confrontadas com a nova versão imediatamente**, mesmo no meio do seu ciclo de teste.

Isso é intencional e é o ponto forte da plataforma: é melhor uma candidata quebrar em homologação por causa de uma mudança que já está em produção, do que passar na homologação contra uma versão desatualizada e quebrar depois de ir para produção. A homologação só tem valor se testar contra o que **realmente** está em produção **agora**.

## Conceito 1 — Atualização (propagação do novo digest produtivo)

Propaga o novo digest produtivo do serviço promovido para **todo lugar no staging que o executa como versão de produção**.

Para o serviço promovido `wallet`, varrer todos os `release.yaml` sob `gitops-staging/wallet/`, **exceto** `candidate/` (que será destruída), e atualizar os que **já têm digest preenchido** (runtime ativo) para o novo digest:

- `wallet/staging/release.yaml` — a instância compartilhada permanente, se houver runtime
- `wallet/client/for-*/release.yaml` — se o wallet roda como client de regressão de outras candidatas

Regra: **só atualiza se o `release.yaml` já tinha digest** (runtime ativo). Se estava vazio (só Service, sem pods), permanece vazio — não se liga um runtime que não existia só porque houve um deploy em produção.

```
para cada release.yaml em gitops-staging/wallet/**:
    se o caminho contém "/candidate/": pular
    se o digest atual não está vazio:
        escrever o novo digest produtivo
```

O Argo CD detecta as mudanças e atualiza os runtimes correspondentes — confrontando cada candidata dependente com a nova versão produtiva.

## Conceito 2 — Limpeza (remoção dos efêmeros da homologação encerrada)

Remove tudo que foi criado especificamente para homologar a candidata que acabou de ser promovida. A chave de busca é o sufixo `for-<service>` e a pasta `candidate/` do próprio serviço.

Para o `wallet` promovido, remove-se por inteiro todas as pastas efêmeras da homologação — regra única (ver decisão 25):

- **Candidata** (`gitops-staging/wallet/candidate/`): remove o **diretório inteiro**. A relação de dependências/clients não se perde — ela vive em `wallet/dependencies.yaml` e `wallet/clients.yaml` (raiz, permanente), não em `candidate/`. O VirtualService do host wallet, gerado a partir dos values da candidata, some junto.
- **Clients que testavam o wallet** (`gitops-staging/*/client/for-wallet/`): remove o **diretório inteiro**.

```
remover todo o diretório gitops-staging/wallet/candidate/
remover todo o diretório gitops-staging/*/client/for-wallet/
```

Em todos os casos, ao sumir o `release.yaml` (junto com a pasta), o ApplicationSet deleta a Application correspondente e, com prune, remove os recursos do cluster (Deployment, Service e VirtualService dos efêmeros). Ver [Argo CD e ApplicationSet](argocd.md).

> **Nota sobre o staging das dependências:** os diretórios `staging/` dos serviços **não** são removidos nesta limpeza — apenas as pastas `for-wallet/`. O `staging/` é permanente (criado no onboarding) e o Service compartilhado permanece como host no mesh (ver decisões 18 e 20).

## Distinção importante entre os dois conceitos

| | Atualização | Limpeza |
|---|-------------|---------|
| Escopo | `gitops-staging/<service>/**` (usos produtivos do serviço) | sufixo `for-<service>` + `<service>/candidate/` |
| O que faz | Reescreve digest para a nova versão | Remove por inteiro as pastas efêmeras (candidate, client) |
| Alcança | Dependências do serviço em **outras** candidatas | Apenas os efêmeros da homologação encerrada |

Exemplo concreto com `wallet` promovido:

- `wallet/client/for-checkout/` → **atualizado** (o wallet roda como client de regressão da candidata checkout; passa a usar o novo wallet produtivo)
- `checkout/client/for-wallet/` → **removido** (foi criado para testar a candidata do wallet; a homologação do wallet terminou)

## Falha no deploy de produção

Se o rollout em produção falhar, **nada é limpo ou atualizado**. O ambiente de homologação é preservado integralmente para investigação. A limpeza e a atualização só ocorrem após confirmação de que o deploy produtivo terminou com sucesso (healthy).

## Por que um script separado (`promote.py`)

O setup da candidata (`orchestrator.py`) e a atualização/limpeza (`promote.py`) ocorrem em momentos distintos do ciclo de vida:

- `orchestrator.py` — o CD (acionado pela Pipeline de CI) quando uma candidata entra em homologação
- `promote.py` — o passo pós-deploy do CD, após o deploy em produção ser concluído com sucesso

São scripts separados no mesmo diretório `orchestrator/`, compartilhando os módulos auxiliares (`manifest.py`, `writer.py`, `validator.py`). Não são projetos distintos — apenas entry points distintos para operações distintas sobre o mesmo repositório.
