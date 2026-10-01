# Arquitetura da Plataforma de Homologação Integrada

## Problema

Em ambientes com muitos microsserviços e squads independentes, testes de integração são difíceis de realizar antes da produção:

- Cada squad testa seu serviço de forma isolada
- Não há validação de fluxos entre domínios antes do deploy
- Falhas de integração são descobertas apenas em produção

## Solução

A plataforma provisiona um ambiente de homologação compartilhado onde uma versão candidata de um serviço é testada contra as versões produtivas vigentes de suas dependências — de forma isolada e sem afetar outros serviços ou a produção.

## Premissas de design

- **Releases independentes** — cada serviço homologa e publica de forma autônoma, sem coordenação com outras squads
- **Uma candidata por serviço** — no máximo uma versão candidata de cada serviço pode estar em homologação simultaneamente
- **Dependências na versão produtiva** — a candidata é sempre testada contra o que está em produção
- **Ambiente isolado** — homologação e produção rodam em clusters e VPCs separados
- **Dados mascarados** — dados produtivos são sanitizados antes de serem usados em homologação

## Componentes

```
┌─────────────────────────────────────────────────────────┐
│                    CI (Jenkins)                         │
│  build · lint · testes unitários · scan · publicação   │
└────────────────────┬────────────────────────────────────┘
                     │ service + digest
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Orquestrador (GitHub Actions)              │
│  lê dependências · resolve digests · atualiza gitops   │
└──────────┬──────────────────────────┬───────────────────┘
           │                          │ lê digests produtivos
           ▼                          ▼
┌──────────────────┐       ┌──────────────────────┐
│  gitops-staging  │       │  gitops-production   │
│  (fonte de       │       │  (fonte de verdade   │
│   verdade hml)   │       │   das versões prod)  │
└────────┬─────────┘       └──────────────────────┘
         │ auto-sync
         ▼
┌─────────────────────────────────────────────────────────┐
│                 GKE Homologação                         │
│                                                         │
│  wallet-candidate   ledger (prod)   checkout-client    │
│       └──────────────────┘               │             │
│                    └─────────────────────┘             │
└─────────────────────────────────────────────────────────┘
```

## Roles dos serviços no cluster de homologação

| Role | Descrição | Ciclo de vida |
|------|-----------|---------------|
| `staging` | Instância compartilhada permanente na versão produtiva | Permanente — atualizada após cada deploy em produção |
| `candidate` | Versão sendo homologada | Efêmera — removida após o ciclo |
| `dependency` | Instância dedicada de uma dependência para um candidate específico | Efêmera — removida após o ciclo |
| `client` | Cliente de regressão dedicado para testar um candidate | Efêmera — removida após o ciclo |

## Estrutura do repositório GitOps de homologação

```
gitops-staging/
  <service>/
    values.yaml                    # configuração base, comum a todos os ambientes
    staging/
      values.yaml                  # overrides do ambiente compartilhado
      release.yaml                 # digest da versão produtiva vigente
    candidate/
      values.yaml                  # overrides do ambiente candidato
      release.yaml                 # digest da candidata (preenchido pelo orquestrador)
    dependency/
      for-<candidate-service>/     # uma pasta por serviço que depende deste
        values.yaml
        release.yaml               # digest produtivo (preenchido pelo orquestrador)
    client/
      for-<candidate-service>/     # uma pasta por candidate que este serviço testa
        values.yaml
        release.yaml               # digest produtivo (preenchido pelo orquestrador)
```

## Ciclo de vida de uma homologação

1. Jenkins executa CI e publica a imagem no registry com o digest imutável
2. Jenkins aciona o GitHub Actions com `service` e `digest`
3. Orquestrador lê `homologation/dependencies.yaml` e `homologation/clients.yaml` do serviço
4. Orquestrador busca os digests produtivos das dependências em `gitops-production`
5. Orquestrador escreve os `release.yaml` no `gitops-staging` e faz commit
6. Argo CD detecta o commit e provisiona os deployments no cluster
7. Testes de integração são executados
8. Se aprovados, PR de promoção é aberto para produção
9. Após deploy em produção, deployments efêmeros são removidos do gitops-staging
