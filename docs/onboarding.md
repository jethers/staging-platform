# Onboarding de Serviços na Plataforma

Guia para integrar um novo serviço (ou um serviço existente) à plataforma de homologação.

---

## Serviço novo

Um serviço que ainda não existe em produção.

### 1. Criar os manifestos de homologação

Dentro do repositório do serviço, criar a pasta `homologation/`:

```
<service>/
  homologation/
    dependencies.yaml
    clients.yaml
```

**`dependencies.yaml`** — lista os serviços dos quais este serviço depende:

```yaml
app: wallet
dependencyMode: shared-preferred
dependencies:
  - ledger
  - antifraud
```

- `dependencyMode: shared-preferred` — usa as instâncias compartilhadas (`staging`) por padrão
- Para forçar instância dedicada de uma dependência, use `dependencyMode: dedicated`

**`clients.yaml`** — lista os serviços que chamam este serviço (clientes de regressão):

```yaml
app: wallet
regressionClients:
  - checkout
```

### 2. Criar os arquivos GitOps de homologação

No repositório `gitops-staging`, criar a estrutura de pastas do serviço:

```
gitops-staging/
  <service>/
    values.yaml                    # configuração base
    staging/
      values.yaml
      release.yaml                 # deixar image.digest vazio
    candidate/
      values.yaml
      release.yaml                 # deixar image.digest vazio
```

Criar as pastas `dependency/for-<service>` e `client/for-<service>` apenas para os serviços declarados em `dependencies.yaml` e `clients.yaml`.

### 3. Primeiro ciclo de homologação

Com o repositório configurado, basta acionar o CI normalmente. O orquestrador irá:

1. Provisionar a candidata com o digest gerado pelo CI
2. Provisionar as dependências com os digests produtivos vigentes
3. Executar os testes de integração
4. Abrir PR de promoção se os testes passarem

Após o primeiro deploy em produção, o `gitops-production` será atualizado automaticamente e o serviço estará disponível como dependência para outros serviços.

---

## Serviço existente

Um serviço que já está em produção mas ainda não usa a plataforma.

### 1. Registrar o digest atual em produção

No repositório `gitops-production`, criar (ou atualizar) o `release.yaml` do serviço com o digest da imagem atualmente em produção:

```yaml
image:
  digest: sha256:<digest-atual>
```

Para descobrir o digest da imagem em execução:

```bash
# Via kubectl
kubectl get deployment <service> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].image}'

# Via Artifact Registry (GCP)
gcloud artifacts docker images describe <registry>/<project>/<repo>/<image>:<tag>
```

> Este passo é feito **uma única vez** durante o onboarding. A partir do próximo deploy em produção, o `gitops-production` será atualizado automaticamente pelo pipeline.

### 2. Seguir os passos do serviço novo

Após registrar o digest, seguir os mesmos passos 1 e 2 descritos na seção anterior.

---

## Erros comuns

### Dependência sem digest em produção

```
ERROR: dependency "ledger" has no production digest in gitops-production/ledger/release.yaml
```

**Causa:** o serviço `ledger` ainda não tem um digest registrado em `gitops-production`.

**Solução:** registrar o digest manualmente (serviço existente) ou aguardar o primeiro deploy em produção do `ledger` (serviço novo).

### Candidata já em homologação

```
ERROR: service "wallet" already has an active candidate in gitops-staging/wallet/candidate/release.yaml
```

**Causa:** já existe um ciclo de homologação em andamento para este serviço.

**Solução:** aguardar o ciclo atual terminar (deploy em produção ou cancelamento manual) antes de iniciar um novo.
