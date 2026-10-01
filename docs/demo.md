# Roteiro de Demo — Plataforma de Homologação Integrada

Este documento é um passo a passo reproduzível para demonstrar a PoC até a
renderização dos Helm charts. Cada etapa indica **o comando**, **o que ele prova**
e **o resultado esperado**. Confirmada a renderização correta, o próximo passo é
subir no GKE (fora do escopo deste roteiro).

Todos os comandos assumem a raiz do projeto como diretório de trabalho:

```bash
cd ~/projetos/staging-platform
```

---

## Pré-requisitos

| Ferramenta | Versão usada na validação | Para quê |
|------------|---------------------------|----------|
| Go | 1.26.x | compilar os serviços |
| Docker | 29.x (com Compose) | buildar imagens e rodar os serviços localmente |
| Helm | 3.22.x | renderizar os charts |
| Python | 3.12.x | rodar o orquestrador |
| PyYAML | 6.0.2 | dependência do orquestrador |

Instalar o PyYAML (se necessário):

```bash
pip3 install -r orchestrator/requirements.txt --break-system-packages
```

> No WSL/Windows, se o `docker compose build` falhar com `docker-credential-desktop.exe not found`,
> remova a linha `"credsStore": "desktop.exe"` de `~/.docker/config.json`.

---

## Visão geral da demo

A demo tem três blocos:

1. **Serviços rodando localmente** (Docker Compose) — prova que `wallet` chama `ledger`
2. **Orquestrador** (setup e promote) — prova a lógica de provisionamento e limpeza no gitops
3. **Renderização dos charts** (helm template) — prova que o gitops gera os manifestos
   corretos para cada papel (staging, candidate, client), incluindo o roteamento Istio

---

## Bloco 1 — Serviços rodando localmente

**Objetivo:** mostrar os dois microsserviços e a comunicação `wallet → ledger`.

### 1.1 Subir os serviços

```bash
docker compose up -d --build
```

**Esperado:** containers `ledger` e `wallet` sobem e ficam `healthy`.

### 1.2 Testar o ledger (serviço de saldo)

```bash
curl -s http://localhost:8081/health
curl -s http://localhost:8081/balance/123
```

**Esperado:**
```json
{"status":"ok","service":"ledger"}
{"account":"123","balance":1150.5,"currency":"BRL","version":"dev"}
```

### 1.3 Testar o wallet (chama o ledger)

```bash
curl -s http://localhost:8082/health
curl -s http://localhost:8082/wallet/123
```

**Esperado:** o wallet responde com os dados enriquecidos, provando que chamou o ledger:
```json
{"status":"ok","service":"wallet"}
{"account":"123","balance":1150.5,"currency":"BRL","wallet_status":"active","version":"dev"}
```

### 1.4 Ver os logs (a chamada wallet → ledger)

```bash
docker compose logs | grep -E "upstream=ledger|path=/wallet|path=/balance"
```

**Esperado:** uma requisição em `/wallet/123` gera log no wallet (requisição recebida +
chamada upstream ao ledger) e no ledger (requisição recebida). O campo `version` aparece
em cada log — será útil para distinguir candidata de produção na demo do cluster.

### 1.5 Encerrar

```bash
docker compose down
```

---

## Bloco 2 — Orquestrador (setup e promote)

**Objetivo:** provar a lógica da plataforma operando sobre o gitops, sem precisar de cluster.
O orquestrador lê os manifestos de homologação e escreve a estrutura efêmera no `gitops-staging`.

**Cenário (fiel ao PPT — fluxo `checkout → wallet → ledger`):** homologar uma nova versão
(candidata) do **wallet**. O **ledger** é dependência do wallet (compartilhada); o **checkout**
é cliente de regressão do wallet (declarado em `gitops-staging/wallet/clients.yaml`).

### 2.1 Preparar o estado base

Para homologar o wallet, o ambiente ao redor dele precisa estar na versão produtiva:

- O **ledger** (dependência) precisa ter runtime ativo no seu `staging/` — a candidata do
  wallet vai consumir o ledger compartilhado.
- O **checkout** (client) precisa ter digest produtivo em `gitops-production` — o client de
  regressão roda a versão produtiva do checkout.

O staging compartilhado de cada serviço espelha a produção (mesmo digest). Usamos valores
fictícios para a demo (num cenário real, vêm do `docker push`):

```bash
# ledger: runtime compartilhado em staging = versão produtiva vigente
LEDGER_PROD_DIGEST="sha256:ledger-prod-xyz"
printf 'image:\n  digest: "%s"\n' "$LEDGER_PROD_DIGEST" > gitops-production/ledger/release.yaml
printf 'image:\n  digest: %s\n'   "$LEDGER_PROD_DIGEST" > gitops-staging/ledger/staging/release.yaml

# checkout: digest produtivo (o orquestrador lê para provisionar o client de regressão)
# (já vem preenchido em gitops-production/checkout/release.yaml no onboarding de exemplo)
grep digest gitops-production/checkout/release.yaml
```

### 2.2 Rodar o orquestrador (simula o Jenkins acionando o GitHub Actions)

O Jenkins buildou uma nova imagem do **wallet** e aciona o orquestrador com o serviço e o
digest da candidata:

```bash
cd orchestrator
GITOPS_STAGING_PATH=$(pwd)/../gitops-staging \
GITOPS_PROD_PATH=$(pwd)/../gitops-production \
python3 orchestrator.py --service wallet --digest sha256:wallet-v2-candidate
cd ..
```

**O que prova:** o orquestrador valida o onboarding do wallet, confirma que a dependência
`ledger` tem runtime compartilhado ativo e que o client `checkout` tem digest produtivo, e
provisiona a candidata do `wallet` + o client `checkout-wallet-client`.

**Esperado:** saída terminando em `✓ gitops-staging atualizado com sucesso`, com os logs:
```
[writer] client atualizado: .../gitops-staging/checkout/client/for-wallet
[writer] candidate atualizado: .../gitops-staging/wallet/candidate
```

### 2.3 Conferir os arquivos gerados

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
- `wallet/candidate/release.yaml` → `digest: sha256:wallet-v2-candidate`
- `checkout/client/for-wallet/values.yaml` → `role: client`, `target: wallet`, `istioInject: true`
- `checkout/client/for-wallet/release.yaml` → o digest produtivo do checkout

### 2.4 Testar a validação de erro (dependência sem runtime)

Prova que o orquestrador falha de forma clara quando uma dependência compartilhada não
tem runtime ativo. O `wallet` depende do `ledger`; se o staging do ledger estiver vazio:

```bash
# esvazia o staging do ledger (simula dependência sem runtime compartilhado)
printf 'image:\n  digest: ""\n' > gitops-staging/ledger/staging/release.yaml

cd orchestrator
GITOPS_STAGING_PATH=$(pwd)/../gitops-staging \
GITOPS_PROD_PATH=$(pwd)/../gitops-production \
python3 orchestrator.py --service wallet --digest sha256:wallet-v2-candidate ; echo "EXIT: $?"
cd ..

# restaura o runtime do ledger para seguir a demo
printf 'image:\n  digest: %s\n' "sha256:ledger-prod-xyz" > gitops-staging/ledger/staging/release.yaml
```

**Esperado:** erro acionável e `EXIT: 1`:
```
✗ ERRO: [validator] Dependência 'ledger' sem runtime compartilhado ativo: digest vazio ...
  → Preencha o digest do runtime compartilhado do 'ledger' ...
```

---

## Bloco 3 — Renderização dos Helm charts

**Objetivo:** provar que o gitops gera os manifestos Kubernetes corretos para cada papel.
Este é o resultado que o Argo CD aplicaria no cluster. Validamos sem cluster via `helm template`.

### 3.1 Lint do chart

```bash
helm lint ./helm/service-chart --set namespace=payments
```

**Esperado:** `1 chart(s) linted, 0 chart(s) failed` (um aviso cosmético de ícone é ok).

### 3.2 Staging SEM runtime → só o Service (host do mesh)

```bash
helm template checkout ./helm/service-chart \
  -f gitops-staging/checkout/values.yaml \
  -f gitops-staging/checkout/staging/values.yaml \
  -f gitops-staging/checkout/staging/release.yaml | grep -E "^kind:|  name:"
```

**Esperado:** apenas `Service` chamado `checkout` (sem Deployment — digest vazio significa
host presente no mesh, sem pods). É o caso de um serviço que existe no mesh mas não tem
runtime compartilhado permanente.

### 3.3 Staging COM runtime → Service + Deployment (ledger, dependência compartilhada)

```bash
helm template ledger ./helm/service-chart \
  -f gitops-staging/ledger/values.yaml \
  -f gitops-staging/ledger/staging/values.yaml \
  --set image.digest=sha256:ledger-prod-xyz | grep -E "^kind:|  name:|image:"
```

**Esperado:** `Service` + `Deployment` chamados `ledger`, imagem com `@sha256:ledger-prod-xyz`.
É a dependência compartilhada que a candidata do wallet vai consumir.

### 3.4 Candidata (wallet) → Service + Deployment + VirtualService (o roteamento)

```bash
helm template wallet-candidate ./helm/service-chart \
  -f gitops-staging/wallet/values.yaml \
  -f gitops-staging/wallet/candidate/values.yaml \
  -f gitops-staging/wallet/candidate/release.yaml
```

**Esperado (os três recursos):**
- `Service` e `Deployment` chamados `wallet-candidate`, imagem `@sha256:wallet-v2-candidate`
- `VirtualService` `wallet-candidate-routes` com:
  - host `wallet.payments.svc.cluster.local`
  - match `sourceLabels: app: checkout-wallet-client` → destino `wallet-candidate...`
  - rota de fallback → `wallet...`

**Este é o coração da demo:** mostra que o tráfego do client de regressão
(`checkout-wallet-client`) é desviado para a candidata, e todo o resto segue para o wallet
compartilhado. É exatamente o cenário do slide 17 do PPT.

### 3.5 Client de regressão (checkout) → Service + Deployment + sidecar, SEM VirtualService

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

## Bloco 4 — Limpeza pós-deploy (promote)

**Objetivo:** provar o fechamento do ciclo — quando a candidata vai para produção, os
efêmeros são removidos e os usos produtivos são atualizados.

O wallet foi aprovado e deployado em produção. O `promote.py` é acionado com o novo
digest produtivo do wallet:

```bash
cd orchestrator
GITOPS_STAGING_PATH=$(pwd)/../gitops-staging \
python3 promote.py --service wallet --digest sha256:wallet-v2-prod
cd ..
```

**Esperado:**
- Atualização: o `wallet/staging/release.yaml` (runtime compartilhado) é atualizado para o
  novo digest produtivo — o compartilhado passa a espelhar a nova produção
- Limpeza: `✓ removido: .../wallet/candidate` e `✓ removido: .../checkout/client/for-wallet`

### Conferir o estado final

```bash
find gitops-staging -type f | sort
```

**Esperado:** só a estrutura permanente de onboarding (values, dependencies, clients,
staging) — todas as pastas efêmeras (`candidate/`, `client/for-*/`) foram removidas.

---

## Restaurar o estado de onboarding limpo (após a demo)

```bash
for svc in wallet ledger checkout; do
  printf '# Imagem da versão produtiva vigente — atualizada após cada deploy em produção\nimage:\n  digest: ""\n' > gitops-staging/$svc/staging/release.yaml
done
git checkout -- gitops-production/   # restaura digests de produção de exemplo
git status --short                   # deve mostrar árvore limpa (ou só o que você quer manter)
```

---

## Checklist de validação da demo

- [ ] Serviços sobem e `wallet /wallet/123` retorna dados do ledger (Bloco 1)
- [ ] Logs mostram a chamada `wallet → ledger` com `version` (Bloco 1.4)
- [ ] Orquestrador provisiona candidata + client corretamente (Bloco 2.2–2.3)
- [ ] Orquestrador falha com erro claro quando dependência não tem runtime (Bloco 2.4)
- [ ] `helm lint` passa (Bloco 3.1)
- [ ] Staging sem digest → só Service; com digest → Service + Deployment (Bloco 3.2–3.3)
- [ ] Candidata gera VirtualService com rota do client + fallback (Bloco 3.4)
- [ ] Client gera sidecar e nenhum VirtualService (Bloco 3.5)
- [ ] Promote remove os efêmeros e atualiza usos produtivos (Bloco 4)

Com todos os itens verificados, a lógica da plataforma está provada localmente. O próximo
passo é provisionar o cluster GKE com Istio e Argo CD, e validar o roteamento em runtime
(o único comportamento que depende do cluster: o Envoy desviando o tráfego real do client
para a candidata).
