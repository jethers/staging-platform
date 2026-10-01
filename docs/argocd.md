# Argo CD e ApplicationSet

Este documento descreve como o Argo CD provisiona e destrói os ambientes de homologação, e como o `release.yaml` controla o ciclo de vida de cada deployment.

## ApplicationSet com file generator

Um único **ApplicationSet** monitora todos os arquivos `release.yaml` do `gitops-staging` via **Git file generator**. Cada `release.yaml` encontrado gera uma **Application** independente.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: staging-services
spec:
  generators:
    - git:
        repoURL: https://github.com/<org>/gitops-staging
        revision: main
        files:
          - path: "**/release.yaml"
  template:
    metadata:
      name: '{{...}}'   # nome derivado do caminho (service + role + target)
    spec:
      source:
        helm:
          # paths relativos ao diretório da situação; o número de "../" depende do nível
          # (staging/ e candidate/ → ../values.yaml; client/for-x/ → ../../../values.yaml)
          valueFiles:
            - <base>/values.yaml  # base do serviço (comum)
            - values.yaml         # overrides do role (role, target)
            - release.yaml        # digest
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

## Duas camadas de responsabilidade

O modelo tem duas camadas independentes que não se confundem:

**Camada 1 — ApplicationSet (controla quais Applications existem):** o Git file generator monitora os `release.yaml` apenas para descobrir **quais Applications devem existir**. Cada `release.yaml` encontrado gera uma Application; removido, deleta a Application. O papel do generator é só a existência.

**Camada 2 — Application (reconcilia o conteúdo):** cada Application gerada aponta para o **diretório** do serviço e lê todos os valueFiles do Helm (base + overrides do role + release). Qualquer mudança em qualquer um desses arquivos sensibiliza a Application e dispara reconciliação no cluster.

```yaml
# cada Application gerada
source:
  path: <service>/<role-dir>        # staging, candidate, client/for-x
  helm:
    valueFiles:
      - <base>/values.yaml           # base do serviço: name, namespace, image, env
      - values.yaml                  # overrides do role: role, target
      - release.yaml                 # digest
```

O path do base (`<base>`) é relativo à situação: `../values.yaml` para `staging/` e `candidate/`, `../../../values.yaml` para `client/for-x/`.

O `release.yaml` serve às duas camadas ao mesmo tempo: para o ApplicationSet é o gatilho de existência; para a Application é um dos valueFiles reconciliados.

## O `release.yaml` é o gatilho de existência

A presença ou ausência de um `release.yaml` controla a existência da Application correspondente:

| Ação no `release.yaml` | Efeito no ApplicationSet | Efeito no cluster |
|------------------------|--------------------------|-------------------|
| Arquivo existe | Application é gerada | Recursos provisionados |
| Arquivo removido | Application é deletada | Recursos removidos (prune) |

Isso define a semântica de limpeza:

- **Efêmeros** (candidate, dependency, client): a limpeza remove a **pasta inteira** → o `release.yaml` some → Application deletada → tudo removido do cluster
- **Staging**: o `release.yaml` **nunca é removido** — permanece sempre (parte do onboarding), mesmo com digest vazio

## Namespace via manifesto (opção escolhida)

O namespace de cada serviço vem do `values.yaml` base e é renderizado pelo chart no `metadata.namespace` de cada recurso. O Argo CD aplica os recursos no namespace que o manifesto declara.

Essa é a abordagem escolhida para o MVP (em vez de `destination.namespace` na Application). Consequências:

- O chart usa `{{ .Values.namespace }}` no `metadata.namespace` dos recursos
- Os namespaces de homologação são criados **previamente** (Terraform ou manifesto base), não sob demanda por serviço
- Mudança de namespace no `values.yaml` de um serviço já provisionado é disruptiva (recreate em outro namespace) — cenário raro e esperado ser disruptivo

A alternativa (`destination.namespace` + `CreateNamespace=true`) criaria namespaces sob demanda, mas exigiria o ApplicationSet parsear o `values.yaml` para popular o `destination`. Fica como evolução futura se a criação dinâmica de namespaces se tornar necessária.

## No staging: o digest controla o Deployment; o Service é permanente

Esta regra vale **apenas para o `staging/`**. Dentro da Application do staging, o chart decide o que renderizar com base no digest:

| `release.yaml` do staging | Service | Deployment |
|---------------------------|---------|------------|
| digest preenchido | renderizado | renderizado (pods rodando) |
| digest vazio | renderizado | **não** renderizado (sem pods) |

Consequências no staging:

- **Esvaziar o digest** do `staging/release.yaml` → o chart deixa de renderizar o Deployment → o Argo CD (com prune) remove o Deployment → **pods eliminadas, Service preservado**
- O Service nunca sai do manifesto renderizado, então o prune nunca o remove — ele é o host permanente no mesh

### Nos efêmeros é diferente: remoção completa

Para candidate, dependency e client, não há "digest condicional preservando Service". A limpeza remove o **diretório inteiro** da pasta efêmera, o que deleta a Application e remove **todos** os recursos daquele efêmero — Service, Deployment e VirtualService. Nada é preservado. Ver [pós-deploy](post-deploy.md).

## Prune é requisito da plataforma

Para que a destruição efetiva ocorra em runtime, o prune automático precisa estar habilitado no ApplicationSet (`syncPolicy.automated.prune: true`). Sem ele:

- Remover um `release.yaml` deletaria a Application, mas deixaria os recursos **órfãos** rodando no cluster
- Esvaziar o digest do staging deixaria o Deployment órfão (pods continuariam rodando)

O prune é **isolado por Application** — cada Application só remove os próprios recursos que saíram do Git. Uma mudança no staging do `wallet` nunca afeta recursos do `ledger` ou de outra Application. Não há risco de prune global no cluster.

## Service compartilhado garantido pelo onboarding

Para que o VirtualService tenha um host válido para rotear, o **Service** do serviço compartilhado precisa existir no mesh. Esse Service é garantido pelo **onboarding**, não criado pela automação: todo serviço, ao ser onboardado, cria sua pasta `staging/` com `release.yaml` (digest vazio quando não há runtime compartilhado).

O orquestrador **não cria** o `staging/` de nenhum serviço. Quando uma candidata (`wallet`) usa uma dependência compartilhada (`ledger`), o orquestrador valida que o `ledger` está onboardado (tem `values.yaml` base e `staging/`) e com runtime ativo; se não estiver, falha com erro explícito. Isso mantém o orquestrador simples — ele só escreve nos arquivos da própria homologação, nunca em estrutura de staging de outros serviços (ver decisão 18).

Um `staging/release.yaml` com digest vazio é um estado válido e permanente: o chart renderiza só o Service (host do mesh), sem Deployment. Promover o serviço a compartilhado real é apenas preencher o digest.

## VirtualService gerado a partir dos values da candidata

O VirtualService do host de um serviço candidato é gerado pelo chart da **própria pasta `candidate/`**, a partir da lista de clients de regressão (que o orquestrador escreve no `candidate/values.yaml`, lida do `clients.yaml`). É um único VirtualService com todas as rotas client → candidata + o fallback.

Não há merge entre recursos nem consolidação concorrente: como há uma candidata por serviço (decisão 2), a homologação daquele serviço é a única dona do VirtualService do host, e o gera inteiro de uma vez (ver decisão 14). O orquestrador escreve os values da candidata; o chart renderiza o VirtualService.
