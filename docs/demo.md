# Roteiro de Demo — Plataforma de Homologação Integrada

Este documento é um passo a passo reproduzível para demonstrar o **núcleo da plataforma**
sem precisar de cluster: a lógica que o orquestrador aplica sobre o gitops e a renderização
dos Helm charts que o Argo CD aplicaria. Cada etapa indica **o comando**, **o que ele prova**
e **o resultado esperado**.

O que esta demo prova:

1. O **setup** do gitops (estado base: produção e staging espelhados)
2. O **orquestrador** manipulando o gitops ao homologar uma candidata (via `simulate-ci.sh`)
3. A **renderização dos templates** (helm template) para cada papel — incluindo o roteamento Istio
4. O **promote** fechando o ciclo (via `simulate-change.sh`): atualização e limpeza

Esta é a demo **local** (sem cluster): prova a lógica rápido e sem custo. Para ver a
plataforma funcionando em runtime no GKE — com o Istio desviando o tráfego de verdade —
veja a demo de cluster em [`demo-cluster.md`](demo-cluster.md). Os serviços **não**
precisam rodar nesta demo local.

Todos os comandos assumem a raiz do projeto como diretório de trabalho:

```bash
cd ~/projetos/staging-platform
```

---

## Pré-requisitos

| Ferramenta | Versão usada na validação | Para quê |
|------------|---------------------------|----------|
| Helm | 3.22.x | renderizar os charts |
| Python | 3.12.x | rodar o orquestrador |
| PyYAML | 6.0.2 | dependência do orquestrador |

Instalar o PyYAML (se necessário):

```bash
pip3 install -r orchestrator/requirements.txt --break-system-packages
```

---

## Cenário (fiel ao PPT — fluxo `checkout → wallet → ledger`)

Vamos homologar uma nova versão (candidata) do **wallet**:

- **ledger** é dependência do wallet (compartilhada) — a candidata consome o ledger compartilhado
- **checkout** é cliente de regressão do wallet — declarado em `gitops-staging/wallet/clients.yaml`

Os três serviços estão onboardados no `gitops-staging` com runtime compartilhado.

---

## Bloco 0 — Setup do gitops (estado base)

**Objetivo:** deixar o gitops no estado base esperado antes da homologação. Num cenário real,
os digests produtivos chegam dos deploys em produção; aqui usamos os **digests reais** das
imagens v1.0.0 publicadas no Artifact Registry, escrevendo o **mesmo digest** em produção e
no staging compartilhado de cada serviço (o runtime compartilhado espelha a produção vigente).

```bash
./scripts/setup-gitops.sh
```

**O que prova:** os pré-requisitos do orquestrador estão satisfeitos — cada serviço tem
runtime compartilhado ativo no staging (necessário para ser dependência) e digest produtivo
registrado (necessário para ser client).

**Esperado:** os 3 serviços (`wallet`, `ledger`, `checkout`) com digest produtivo em
`gitops-production/<svc>/release.yaml` e o mesmo digest em `gitops-staging/<svc>/staging/release.yaml`.

### Confirmar o estado base (opcional)

```bash
git status --short gitops-staging gitops-production
```

**Esperado:** só os seis `release.yaml` modificados (produção + staging dos três serviços).

---

## Bloco 1 — Orquestrador homologando a candidata do wallet

**Objetivo:** provar a lógica da plataforma operando sobre o gitops. O `simulate-ci.sh`
reproduz a Pipeline de CI acionando o CD (o orquestrador) com o serviço e o digest da
candidata. O build/scan/push da imagem é responsabilidade do CI — fora do escopo do projeto.

### 1.1 Snapshot "antes"

```bash
git status --short gitops-staging
```

Guarde esse estado como referência. A única diferença após o Bloco 1 deve ser a criação das
pastas efêmeras `wallet/candidate/` e `checkout/client/for-wallet/`.

### 1.2 Rodar a homologação (simula a Pipeline de CI → CD/orquestrador)

```bash
./scripts/simulate-ci.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0
```

**O que prova:** o orquestrador valida o onboarding do wallet, confirma que a dependência
`ledger` tem runtime compartilhado ativo e que o client `checkout` tem digest produtivo, e
então provisiona a candidata do `wallet` + o client `checkout-wallet-client`.

**Esperado:** saída terminando em `✓ gitops-staging atualizado com sucesso`, com os logs:
```
[writer] client atualizado: .../gitops-staging/checkout/client/for-wallet
[writer] candidate atualizado: .../gitops-staging/wallet/candidate
```

### 1.3 Conferir o que mudou no gitops (o "depois")

```bash
git status --short gitops-staging
```

**Esperado:** além dos release.yaml do setup, só duas pastas novas (untracked):
```
?? gitops-staging/checkout/client/
?? gitops-staging/wallet/candidate/
```

### 1.4 Conferir os arquivos gerados

```bash
echo "--- candidata do wallet ---"
cat gitops-staging/wallet/candidate/values.yaml
cat gitops-staging/wallet/candidate/release.yaml
echo "--- client checkout-for-wallet ---"
cat gitops-staging/checkout/client/for-wallet/values.yaml
cat gitops-staging/checkout/client/for-wallet/release.yaml
```

**Esperado:**
- `wallet/candidate/values.yaml` → `role: candidate` + `clients: [checkout-wallet-client]`
- `wallet/candidate/release.yaml` → `digest: sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0`
- `checkout/client/for-wallet/values.yaml` → `role: client`, `target: wallet`, `istioInject: true`
- `checkout/client/for-wallet/release.yaml` → o digest produtivo do checkout (`sha256:c377e7c566922b44291a3d5f7da1f17106f2562fe5bd1b0fafc7739720d81ba0`)

### 1.5 Testar a validação de erro (dependência sem runtime)

Prova que o orquestrador falha de forma clara quando uma dependência compartilhada não tem
runtime ativo. O `wallet` depende do `ledger`; se o staging do ledger estiver vazio:

```bash
# esvazia o staging do ledger (simula dependência sem runtime compartilhado)
printf 'image:\n  digest: ""\n' > gitops-staging/ledger/staging/release.yaml

./scripts/simulate-ci.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0 ; echo "EXIT: $?"

# restaura o runtime do ledger para seguir a demo
./scripts/setup-gitops.sh >/dev/null
```

**Esperado:** erro acionável e `EXIT: 1`:
```
✗ ERRO: [validator] Dependência 'ledger' sem runtime compartilhado ativo: digest vazio ...
  → Preencha o digest do runtime compartilhado do 'ledger' ...
```

---

## Bloco 2 — Renderização dos Helm charts

**Objetivo:** provar que o gitops gera os manifestos Kubernetes corretos para cada papel.
Este é o resultado que o Argo CD aplicaria no cluster. Validamos sem cluster via `helm template`.

### 2.1 Lint do chart

```bash
helm lint ./helm/service-chart --set namespace=payments
```

**Esperado:** `1 chart(s) linted, 0 chart(s) failed` (um aviso cosmético de ícone é ok).

### 2.2 Staging COM runtime → Service + Deployment (ledger, dependência compartilhada)

```bash
helm template ledger ./helm/service-chart \
  -f gitops-staging/ledger/values.yaml \
  -f gitops-staging/ledger/staging/values.yaml \
  -f gitops-staging/ledger/staging/release.yaml | grep -E "^kind:|  name:|@sha256"
```

**Esperado:** `Service` + `Deployment` chamados `ledger`, imagem com `@sha256:e966d211ddc0c084b23fe69caf6663d6e46bcaabc31ad229c8498881b97f5c02`.
É a dependência compartilhada que a candidata do wallet consome.

### 2.3 Candidata (wallet) → Service + Deployment + VirtualService (o roteamento)

```bash
helm template wallet-candidate ./helm/service-chart \
  -f gitops-staging/wallet/values.yaml \
  -f gitops-staging/wallet/candidate/values.yaml \
  -f gitops-staging/wallet/candidate/release.yaml
```

**Esperado (os três recursos):**
- `Service` e `Deployment` chamados `wallet-candidate`, imagem `@sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0`
- `VirtualService` `wallet-candidate-routes` com:
  - host `wallet.payments.svc.cluster.local`
  - match `sourceLabels: app: checkout-wallet-client` → destino `wallet-candidate...`
  - rota de fallback → `wallet...`

**Este é o coração da demo:** mostra que o tráfego do client de regressão
(`checkout-wallet-client`) é desviado para a candidata, e todo o resto segue para o wallet
compartilhado. É exatamente o cenário do slide 17 do PPT.

### 2.4 Client de regressão (checkout) → Service + Deployment + sidecar, SEM VirtualService

```bash
helm template checkout-wallet-client ./helm/service-chart \
  -f gitops-staging/checkout/values.yaml \
  -f gitops-staging/checkout/client/for-wallet/values.yaml \
  -f gitops-staging/checkout/client/for-wallet/release.yaml | grep -E "^kind:|  name:|sidecar|  app:"
```

**Esperado:**
- `Service` + `Deployment` chamados `checkout-wallet-client`
- label `app: checkout-wallet-client` (o mesmo que o VirtualService da candidata usa no match)
- annotation `sidecar.istio.io/inject: "true"` (o client origina o desvio)
- **nenhum** VirtualService (o client não gera VS)

---

## Bloco 3 — Promote (fechamento do ciclo na janela de change)

**Objetivo:** provar o fechamento do ciclo. O `simulate-change.sh` condensa a etapa de
change da Pipeline de CD (janela de change aprovada), em dois passos na ordem correta:
1. atualiza o `gitops-production/wallet/release.yaml` com o novo digest (o merge do PR de
   promoção) — **se este passo falhar, o promote não roda**;
2. executa o `promote.py` (pós-deploy): espelha o digest no runtime compartilhado do staging
   e remove os efêmeros.

```bash
./scripts/simulate-change.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0
```

**Esperado:**
- Produção: `gitops-production/wallet/release.yaml` atualizado para o novo digest (merge do PR)
- Atualização: `wallet/staging/release.yaml` (runtime compartilhado) espelha o novo digest
- Limpeza: `✓ removido: .../wallet/candidate` e `✓ removido: .../checkout/client/for-wallet`

### Conferir o estado final

```bash
git status --short gitops-staging gitops-production
```

**Esperado:** as pastas efêmeras (`candidate/`, `client/for-*/`) sumiram; `wallet/staging/release.yaml`
e `gitops-production/wallet/release.yaml` com o novo digest.

---

## Restaurar o estado de onboarding limpo (após a demo)

```bash
git checkout -- gitops-staging gitops-production
git status --short                    # deve mostrar árvore limpa (só os scripts, se novos)
```

---

## Checklist de validação da demo

- [ ] `setup-gitops.sh` deixa os 3 serviços com runtime e digest produtivo (Bloco 0)
- [ ] `simulate-ci.sh wallet` provisiona candidata + client corretamente (Bloco 1.2–1.4)
- [ ] `git status` após o Bloco 1 mostra só `candidate/` e `client/for-wallet/` novos (Bloco 1.3)
- [ ] Orquestrador falha com erro claro quando dependência não tem runtime (Bloco 1.5)
- [ ] `helm lint` passa (Bloco 2.1)
- [ ] Staging com digest → Service + Deployment (Bloco 2.2)
- [ ] Candidata gera VirtualService com rota do client + fallback (Bloco 2.3)
- [ ] Client gera sidecar e nenhum VirtualService (Bloco 2.4)
- [ ] `simulate-change.sh` atualiza produção, espelha no compartilhado e remove os efêmeros (Bloco 3)

Com todos os itens verificados, a lógica da plataforma está provada localmente. Para ver o
comportamento que depende do cluster — o Envoy desviando o tráfego real do client para a
candidata — siga a demo de cluster em [`demo-cluster.md`](demo-cluster.md).
