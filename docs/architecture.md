# Arquitetura da Plataforma de Homologação Integrada

## Problema

Em ambientes com muitos microsserviços e squads independentes, testes de integração são difíceis de realizar antes da produção:

- Cada squad testa seu serviço de forma isolada
- Não há validação de fluxos entre domínios antes do deploy
- Falhas de integração são descobertas apenas em produção

## Solução

A plataforma provisiona um ambiente de homologação compartilhado onde uma versão candidata de um serviço é testada contra as versões produtivas vigentes de suas dependências — de forma isolada e sem afetar outros serviços ou a produção. O desvio de tráfego dos clients de regressão para a candidata é feito de forma transparente pelo Istio, sem exigir alterações no código das aplicações. No MVP, as dependências são sempre compartilhadas (ver decisão 19).

## Premissas de design

- **Releases independentes** — cada serviço homologa e publica de forma autônoma, sem coordenação com outras squads
- **Uma candidata por serviço** — no máximo uma versão candidata de cada serviço pode estar em homologação simultaneamente
- **Dependências na versão produtiva** — a candidata é sempre testada contra o que está em produção
- **Homologação reflete produção continuamente** — quando um serviço muda em produção, as candidatas que dependem dele são confrontadas com a nova versão imediatamente
- **Roteamento transparente** — o desvio é feito pelo Istio sem assumir que as aplicações externalizam os endpoints de suas dependências
- **Ambiente isolado** — homologação e produção rodam em clusters e VPCs separados
- **Dados mascarados** — dados produtivos são sanitizados antes de serem usados em homologação

## Componentes

```
┌─────────────────────────────────────────────────────────┐
│                    CI (Jenkins)                          │
│   build · lint · testes unitários · scan · publicação    │
└────────────────────┬─────────────────────────────────────┘
                     │ service + digest
                     ▼
┌──────────────────────────────────────────────────────────┐
│         GitHub Actions — setup (orchestrator.py)         │
│   lê manifestos · resolve digests prod · escreve staging │
└──────────┬───────────────────────────────┬───────────────┘
           │                               │ lê digests produtivos
           ▼                               ▼
┌──────────────────────┐       ┌──────────────────────┐
│  gitops-staging      │       │  gitops-production   │
│  (monorepo, fonte    │       │  (repo separado,     │
│   de verdade da hml) │       │   versões em prod)   │
└────────┬─────────────┘       └──────────────────────┘
         │ auto-sync
         ▼
┌──────────────────────────────────────────────────────────┐
│                     GKE Homologação                      │
│  candidata · clients de regressão dedicados             │
│  dependências e staging compartilhados                   │
│  roteamento client → candidata via Istio (VirtualService)│
└──────────────────────────────────────────────────────────┘

Após deploy em produção:
┌──────────────────────────────────────────────────────────┐
│       GitHub Actions — promote (promote.py)              │
│   atualiza usos produtivos em hml · remove efêmeros      │
└──────────────────────────────────────────────────────────┘
```

## Roles dos serviços no cluster de homologação

> **O que é "role" aqui:** é apenas um valor de configuração do Helm (um campo no `values.yaml`, ex.: `role: candidate`), **não** um RBAC Role do Kubernetes nem um IAM Role da AWS. O chart lê esse valor em tempo de renderização para decidir o nome do recurso, o label `app` e se injeta o sidecar Istio. Após a renderização, o `role` não existe como objeto no cluster — o que fica no pod é o nome, o label `app` e a annotation. Uma mesma imagem de serviço roda em situações diferentes (staging, candidate, dependency, client) apenas mudando esse valor.

| Role | Descrição | Nome do recurso | Sidecar Istio | Ciclo de vida |
|------|-----------|-----------------|---------------|---------------|
| `staging` | Instância compartilhada na versão produtiva | `<service>` | Não | Permanente (Service sempre; Deployment só se houver runtime) |
| `candidate` | Versão sendo homologada | `<service>-candidate` | Não (MVP) | Efêmera |
| `client` | Cliente de regressão de uma candidata | `<service>-<target>-client` | Sim | Efêmera |

A injeção do sidecar é controlada pela flag `istioInject` (setada pelo orquestrador), não derivada diretamente do role — ver decisão 11. O role `dependency` existe no chart para evolução futura (dependências dedicadas), mas não é usado no MVP (ver decisão 19).

Onde `<target>` é sempre o serviço candidato que a dependência ou o client serve.

## O Service compartilhado é permanente; o Deployment é condicional

Para que o Istio tenha um host válido para rotear, o **Service** do serviço compartilhado precisa existir sempre em staging — mesmo sem pods. O **Deployment** em staging só é renderizado quando `staging/release.yaml` tem digest preenchido (há runtime compartilhado ativo). Um serviço pode existir apenas como host no mesh, sem runtime, até ser alvo de rotas.

O provisionamento é feito por um **ApplicationSet** que monitora os `release.yaml` do `gitops-staging`: cada `release.yaml` gera uma Application. A presença/ausência do arquivo controla a existência da Application, e o digest controla se há Deployment. Ver [Argo CD e ApplicationSet](argocd.md) e [roteamento](routing.md).

## Estrutura do repositório GitOps de homologação (monorepo)

```
gitops-staging/
  <service>/
    # --- permanente (onboarding) ---
    values.yaml
    dependencies.yaml
    clients.yaml
    staging/
      values.yaml
      release.yaml
    # --- efêmero (criado pelo orquestrador, removido na limpeza) ---
    candidate/
      values.yaml
      release.yaml
    client/
      for-<candidate>/
        values.yaml
        release.yaml
```

> No MVP não há pasta `dependency/for-*/` — dependências são compartilhadas (decisão 19). O role `dependency` fica reservado para evolução futura.

Significado de cada item:

- **`values.yaml`** (raiz) — configuração **comum** às quatro situações: a identidade do serviço (name, namespace, image, service.port, env, resources). As quatro situações abaixo herdam dele e só adicionam o que as diferencia (ver decisão 26)
- **`dependencies.yaml`** — dependências do serviço, com o modo de cada uma (metadados lidos pelo orquestrador)
- **`clients.yaml`** — clients de regressão do serviço (metadados lidos pelo orquestrador)
- **`staging/`** — instância compartilhada (permanente, via onboarding). `values.yaml` só com `role: staging`. O `release.yaml` tem o digest produtivo vigente; vazio significa só Service, sem runtime
- **`candidate/`** — versão em homologação (**efêmera**, criada pelo orquestrador, removida na limpeza). `values.yaml` com `role: candidate` + a lista de clients (para o VirtualService); `release.yaml` com o digest da candidata
- **`client/for-<candidate>/`** — uma pasta por candidata que este serviço testa (**efêmera**). `values.yaml` com `role: client` + `target: <candidate>`. Criada pelo orquestrador

As pastas `staging/`, mais o `values.yaml` base, `dependencies.yaml` e `clients.yaml`, são **permanentes** (criadas no onboarding). As pastas `candidate/` e `client/for-*/` são **efêmeras** (criadas pelo orquestrador no setup, removidas na limpeza).

Os manifestos `dependencies.yaml` e `clients.yaml` ficam no `gitops-staging` (não no repositório do serviço), para que o CD leia tudo de um único lugar. O `gitops-staging` é um **monorepo** que mantém todos os serviços de homologação numa árvore única (ver [decisões](decisions.md), item 15).

## Ciclo de vida de uma homologação

1. Jenkins executa o CI e publica a imagem no registry com o digest imutável
2. Jenkins aciona o GitHub Actions passando `service` e `digest`
3. `orchestrator.py` lê `dependencies.yaml` e `clients.yaml` do serviço no `gitops-staging`
4. Resolve os digests produtivos das dependências e clients em `gitops-production` (erro explícito se faltar)
5. Cria as pastas efêmeras no `gitops-staging` (candidata e clients de regressão) com seus `values.yaml` e `release.yaml`, e faz commit/push
6. Argo CD detecta o commit e provisiona candidata, clients e o VirtualService (rotas client → candidata)
7. A pipeline aguarda `Synced/Healthy` e executa os testes de integração
8. Testes OK → abre PR de promoção para produção; FAIL → preserva o ambiente para investigação
9. Após o deploy em produção, `promote.py` atualiza os usos produtivos do serviço em homologação (staging compartilhado) e remove os efêmeros da homologação encerrada (ver [pós-deploy](post-deploy.md))

## Fonte de verdade das versões produtivas

O orquestrador lê os digests produtivos do repositório `gitops-production`, não do cluster de produção. Isso desacopla a plataforma de homologação do mecanismo de deploy de produção — qualquer CD pode atualizar o `gitops-production` ao finalizar um deploy. Dependência ou client sem digest registrado resulta em erro explícito (ver [decisões](decisions.md), item 4).
