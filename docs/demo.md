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

**Cenário:** homologar uma nova versão (candidata) do `ledger`. O `wallet` é cliente de
regressão do `ledger` (declarado em `gitops-staging/ledger/clients.yaml`).

### 2.1 Preparar o estado base

As dependências compartilhadas precisam ter runtime ativo no staging (digest preenchido),
e os serviços precisam de digest produtivo registrado. Para a demo, usamos valores fictícios:

```bash
# runtime compartilhado do wallet em staging (o wallet é client; precisa existir no mesh)
printf 'image:\n  digest: sha256:wallet-staging-prod\n' > gitops-staging/wallet/staging/release.yaml

# digest produtivo do wallet (lido pelo orquestrador ao provisionar o client)
grep -q 'digest: "' gitops-production/wallet/release.yaml && echo "wallet prod OK" || \
  printf 'image:\n  digest: "sha256:wallet-prod-abc"\n' > gitops-production/wallet/release.yaml
```

### 2.2 Rodar o orquestrador (simula o Jenkins acionando o GitHub Actions)

```bash
cd orchestrator
GITOPS_STAGING_PATH=$(pwd)/../gitops-staging \
GITOPS_PROD_PATH=$(pwd)/../gitops-production \
python3 orchestrator.py --service ledger --digest sha256:ledger-v2-candidate
cd ..
```

**O que prova:** o orquestrador valida o onboarding, confirma que o `wallet` (client) tem
digest produtivo, e provisiona a candidata do `ledger` + o client `wallet-ledger-client`.

**Esperado:** saída terminando em `✓ gitops-staging atualizado com sucesso`, com os logs:
```
[writer] client atualizado: .../gitops-staging/wallet/client/for-ledger
[writer] candidate atualizado: .../gitops-staging/ledger/candidate
```

### 2.3 Conferir os arquivos gerados

```bash
echo "--- candidata do ledger ---"
cat gitops-staging/ledger/candidate/values.yaml
cat gitops-staging/ledger/candidate/release.yaml
echo "--- client wallet-for-ledger ---"
cat gitops-staging/wallet/client/for-ledger/values.yaml
cat gitops-staging/wallet/client/for-ledger/release.yaml
```

**Esperado:**
- `ledger/candidate/values.yaml` → `role: candidate` + `clients: [wallet-ledger-client]`
- `ledger/candidate/release.yaml` → `digest: sha256:ledger-v2-candidate`
- `wallet/client/for-ledger/values.yaml` → `role: client`, `target: ledger`, `istioInject: true`
- `wallet/client/for-ledger/release.yaml` → o digest produtivo do wallet

### 2.4 Testar a validação de erro (dependência sem runtime)

Prova que o orquestrador falha de forma clara quando uma dependência compartilhada não
tem runtime ativo. O `wallet` depende do `ledger`; se o staging do ledger estiver vazio:

```bash
# garante o staging do ledger vazio
printf 'image:\n  digest: ""\n' > gitops-staging/ledger/staging/release.yaml

cd orchestrator
GITOPS_STAGING_PATH=$(pwd)/../gitops-staging \
GITOPS_PROD_PATH=$(pwd)/../gitops-production \
python3 orchestrator.py --service wallet --digest sha256:wallet-v2-candidate ; echo "EXIT: $?"
cd ..
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
helm template ledger ./helm/service-chart \
  -f gitops-staging/ledger/values.yaml \
  -f gitops-staging/ledger/staging/values.yaml \
  -f gitops-staging/ledger/staging/release.yaml | grep -E "^kind:|  name:"
```

**Esperado:** apenas `Service` chamado `ledger` (sem Deployment — digest vazio significa
host presente no mesh, sem pods).

### 3.3 Staging COM runtime → Service + Deployment

```bash
helm template ledger ./helm/service-chart \
  -f gitops-staging/ledger/values.yaml \
  -f gitops-staging/ledger/staging/values.yaml \
  --set image.digest=sha256:ledger-staging-prod | grep -E "^kind:|  name:|image:"
```

**Esperado:** `Service` + `Deployment` chamados `ledger`, imagem com `@sha256:ledger-staging-prod`.

### 3.4 Candidata → Service + Deployment + VirtualService (o roteamento)

```bash
helm template ledger-candidate ./helm/service-chart \
  -f gitops-staging/ledger/values.yaml \
  -f gitops-staging/ledger/candidate/values.yaml \
  -f gitops-staging/ledger/candidate/release.yaml
```

**Esperado (os três recursos):**
- `Service` e `Deployment` chamados `ledger-candidate`, imagem `@sha256:ledger-v2-candidate`
- `VirtualService` `ledger-candidate-routes` com:
  - host `ledger.payments.svc.cluster.local`
  - match `sourceLabels: app: wallet-ledger-client` → destino `ledger-candidate...`
  - rota de fallback → `ledger...`

**Este é o coração da demo:** mostra que o tráfego do client de regressão
(`wallet-ledger-client`) é desviado para a candidata, e todo o resto segue para o ledger
compartilhado.

### 3.5 Client de regressão → Service + Deployment + sidecar, SEM VirtualService

```bash
helm template wallet-ledger-client ./helm/service-chart \
  -f gitops-staging/wallet/values.yaml \
  -f gitops-staging/wallet/client/for-ledger/values.yaml \
  -f gitops-staging/wallet/client/for-ledger/release.yaml | grep -E "^kind:|  name:|sidecar|  app:"
```

**Esperado:**
- `Service` + `Deployment` chamados `wallet-ledger-client`
- label `app: wallet-ledger-client` (o mesmo que o VirtualService da candidata usa no match)
- annotation `sidecar.istio.io/inject: "true"` (o client origina o desvio)
- **nenhum** VirtualService (o client não gera VS)

---

## Bloco 4 — Limpeza pós-deploy (promote)

**Objetivo:** provar o fechamento do ciclo — quando a candidata vai para produção, os
efêmeros são removidos e os usos produtivos são atualizados.

```bash
cd orchestrator
GITOPS_STAGING_PATH=$(pwd)/../gitops-staging \
python3 promote.py --service ledger --digest sha256:ledger-v2-prod
cd ..
```

**Esperado:**
- Atualização: se o staging do ledger tiver runtime, seu digest é atualizado para o novo
- Limpeza: `✓ removido: .../ledger/candidate` e `✓ removido: .../wallet/client/for-ledger`

### Conferir o estado final

```bash
find gitops-staging -type f | sort
```

**Esperado:** só a estrutura permanente de onboarding (values, dependencies, clients,
staging) — todas as pastas efêmeras (`candidate/`, `client/for-*/`) foram removidas.

---

## Restaurar o estado de onboarding limpo (após a demo)

```bash
printf '# Imagem da versão produtiva vigente — atualizada após cada deploy em produção\nimage:\n  digest: ""\n' > gitops-staging/ledger/staging/release.yaml
printf '# Imagem da versão produtiva vigente — atualizada após cada deploy em produção\nimage:\n  digest: ""\n' > gitops-staging/wallet/staging/release.yaml
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
