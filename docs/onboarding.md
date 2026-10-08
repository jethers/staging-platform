# Onboarding de Serviços na Plataforma

Guia para integrar um novo serviço (ou um serviço existente) à plataforma de homologação. Todos os manifestos ficam no monorepo `gitops-staging`.

---

## Serviço novo

Um serviço que ainda não existe em produção.

### 1. Criar a estrutura base no gitops-staging

```
gitops-staging/
  <service>/
    values.yaml            # configuração base
    dependencies.yaml      # dependências do serviço
    clients.yaml           # clients de regressão do serviço
    staging/
      values.yaml          # role: staging
      release.yaml         # image.digest vazio (só Service, sem runtime)
```

> O onboarding cria apenas a parte **permanente**: `values.yaml` base, `dependencies.yaml`, `clients.yaml` e a pasta `staging/`. A pasta `candidate/` **não** faz parte do onboarding — é criada pelo orquestrador quando a homologação é disparada, e removida na limpeza (efêmera). As pastas `client/for-*/` também são criadas pelo orquestrador. (No MVP não há pasta `dependency/for-*/` — dependências são compartilhadas; ver decisão 19.)
>
> O orquestrador não cria a config permanente — se faltar quando o serviço for usado (como candidata, dependência ou client), ele falha com erro "serviço não onboardado" (ver decisões 18 e 20). A pasta `staging/` garante o Service (host no mesh) mesmo sem runtime; deixe `release.yaml` com digest vazio se não houver versão compartilhada.

**`values.yaml`** (base) — define nome, namespace, imagem e config comum:

```yaml
name: wallet
namespace: payments
image:
  repository: <org>/wallet
  pullPolicy: IfNotPresent
service:
  port: 8080
env:
  - name: PORT
    value: "8080"
```

**`dependencies.yaml`** — serviços dos quais este depende (lista simples; no MVP todas são compartilhadas, ver decisão 19):

```yaml
app: wallet
dependencies:
  - ledger
```

A candidata chama cada dependência no host compartilhado. Cada dependência precisa estar onboardada e com runtime ativo no seu `staging/` (digest preenchido), para a candidata consumi-la.

**`clients.yaml`** — serviços que chamam este (clientes de regressão):

```yaml
app: wallet
regressionClients:
  - checkout
```

### 2. Garantir que as dependências e clients estão onboardados

A pasta `client/for-<candidate>/` **não** é criada manualmente no onboarding — o orquestrador a gera durante o setup da homologação (com `role`, `target` e o digest produtivo). O mesmo vale para a pasta `candidate/`.

O que o onboarding precisa garantir é que **cada serviço citado** como dependência (no `dependencies.yaml`) ou como client (no `clients.yaml`) **esteja ele próprio onboardado** — ou seja, tenha seu `values.yaml` base e sua pasta `staging/` (passo 1). Exemplo para o `wallet`:

- `ledger` (dependência do wallet) → o `ledger` precisa ter `gitops-staging/ledger/values.yaml` + `gitops-staging/ledger/staging/` com runtime ativo
- `checkout` (client do wallet) → o `checkout` precisa ter `gitops-staging/checkout/values.yaml` + `gitops-staging/checkout/staging/`

Além disso, cada um precisa ter o digest produtivo registrado no `gitops-production` (ver seção "Serviço existente" e decisão 5).

### 3. Primeiro ciclo de homologação

Com a estrutura pronta, acionar o CI normalmente. O orquestrador provisiona a candidata e os clients com os digests produtivos vigentes, a pipeline roda os testes e, se aprovados, abre o PR de promoção.

Após o primeiro deploy em produção, o `gitops-production` é atualizado automaticamente e o serviço fica disponível como dependência para outros.

---

## Serviço existente

Um serviço que já está em produção mas ainda não usa a plataforma.

### 1. Registrar o digest atual em produção

No `gitops-production`, criar/atualizar o `release.yaml` do serviço com o digest da imagem atualmente em produção:

```yaml
image:
  digest: sha256:<digest-atual>
```

Para descobrir o digest em execução:

```bash
# Via kubectl
kubectl get deployment <service> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].image}'

# Via Artifact Registry (GCP)
gcloud artifacts docker images describe <registry>/<project>/<repo>/<image>:<tag>
```

> Feito **uma única vez** no onboarding. A partir do próximo deploy em produção, o `gitops-production` é atualizado automaticamente.

### 2. Seguir os passos do serviço novo

Após registrar o digest, seguir os passos 1 e 2 da seção anterior.

---

## Erros comuns

### Dependência/client sem digest em produção

```
[validator] Digest de produção vazio para dependência 'ledger'
```

**Causa:** o serviço ainda não tem digest registrado em `gitops-production`.

**Solução:** registrar o digest manualmente (serviço existente) ou aguardar o primeiro deploy em produção (serviço novo). Toda dependência precisa ter passado pela pipeline ou sido registrada no onboarding — nada chega a ser dependência sem estar em produção.

### Serviço não onboardado (values.yaml base ou staging ausente)

```
[validator] Serviço 'ledger' não onboardado: values.yaml base ou staging/ ausente
```

**Causa:** um serviço citado como dependência ou client não tem o `values.yaml` base e/ou a pasta `staging/`. O orquestrador não cria essa estrutura base (ver decisões 18 e 20) — ele só cria as pastas `candidate/` e `client/for-<candidate>/` durante o setup, mas isso exige que o serviço-alvo já esteja onboardado.

**Solução:** onboardar o serviço — criar `<service>/values.yaml` (base) e `<service>/staging/` (com `values.yaml` role: staging e `release.yaml`).
