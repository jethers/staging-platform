# Orquestrador de Homologação

O orquestrador é o componente central da plataforma. É acionado pelo CI (Jenkins) ao final de um build bem-sucedido e é responsável por preparar o ambiente de homologação no cluster.

## Responsabilidades

1. Validar que não há candidata ativa para o serviço
2. Resolver os digests produtivos das dependências e clients
3. Escrever os `release.yaml` no `gitops-staging`
4. Fazer commit e push — o Argo CD cuida do resto

## Fluxo detalhado

```
Jenkins
  └── aciona GitHub Actions com:
        service=wallet
        digest=sha256:abc123...
        
GitHub Actions (orquestrador)
  1. Valida: gitops-staging/wallet/candidate/release.yaml está vazio?
     └── Se não: erro — candidata já em homologação
     
  2. Lê: services/wallet/homologation/dependencies.yaml
     └── dependencies: [ledger]
     
  3. Lê: services/wallet/homologation/clients.yaml
     └── regressionClients: [checkout]  (não declarado no exemplo atual)

  4. Para cada dependência (ledger):
     └── Lê: gitops-production/ledger/release.yaml
         └── Se image.digest vazio: erro — dependência sem versão em produção
         └── Se preenchido: usa o digest

  5. Escreve os release.yaml:
     └── gitops-staging/wallet/candidate/release.yaml     ← digest da candidata
     └── gitops-staging/ledger/dependency/for-wallet/release.yaml  ← digest prod do ledger

  6. Commit + push no gitops-staging
  
Argo CD
  └── detecta o commit → provisiona no cluster
  
GitHub Actions (continuação)
  7. Aguarda Argo CD reportar Synced/Healthy
  8. Executa testes de integração
  9. Testes OK → abre PR de promoção para produção
     Testes FAIL → notifica squad, preserva ambiente para investigação
```

## Entradas

| Parâmetro | Descrição | Exemplo |
|-----------|-----------|---------|
| `service` | Nome do serviço sendo homologado | `wallet` |
| `digest` | Digest SHA-256 da imagem candidata | `sha256:abc123...` |

## Regras de negócio

- **Uma candidata por serviço** — se `gitops-staging/<service>/candidate/release.yaml` já tiver um digest preenchido, o orquestrador falha com erro explícito
- **Dependência sem digest produtivo** — se `gitops-production/<dep>/release.yaml` estiver com `image.digest` vazio, o orquestrador falha com erro explícito
- **Digests imutáveis** — o orquestrador sempre usa digest SHA-256, nunca tags mutáveis como `latest`

## Limpeza pós-deploy

Após o deploy em produção:

1. O `gitops-production/<service>/release.yaml` é atualizado com o novo digest
2. O `gitops-staging/<service>/candidate/release.yaml` é esvaziado (`image.digest: ""`)
3. As pastas `dependency/for-<service>` e `client/for-<service>` dos serviços dependentes são esvaziadas
4. O Argo CD com `prune` ativado remove os deployments efêmeros do cluster

Se o deploy em produção falhar, o ambiente de homologação é preservado para investigação.

## Simulação local (PoC)

Na PoC, o Jenkins é simulado por um script que passa `service` e `digest` diretamente para o orquestrador. O orquestrador é um script que opera sobre os arquivos locais do repositório, sem precisar de cluster para ser testado.
