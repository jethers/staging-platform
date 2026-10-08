# Staging Platform — PoC de Homologação Integrada

Plataforma de homologação integrada para microsserviços. Uma versão **candidata** de um
serviço é testada contra as versões **produtivas** de suas dependências, num ambiente
compartilhado e isolado, com o tráfego dos clients de regressão desviado para a candidata
de forma transparente pelo **Istio** — sem alterar o código das aplicações.

O fluxo é **GitOps**: a automação transforma um gatilho `(service, digest)` em alterações
versionadas nos repositórios gitops; o **Argo CD** aplica no cluster.

> Status: PoC validada end-to-end num cluster **GKE Autopilot** real — incluindo o
> roteamento Istio em runtime (ver [demo de cluster](docs/demo-cluster.md)).

---

## Fronteiras de escopo (resumo)

Para evitar ambiguidade sobre o que a plataforma faz:

- **Entra pronto (premissa):**
  - o **CI de cada serviço** builda, escaneia e publica a imagem candidata, e ao final
    **aciona o CD** (o orquestrador) com `service` + `digest`. A ferramenta de CI/CD é
    intercambiável (GitHub Actions, GitLab CI, Jenkins, …);
  - um **cluster Kubernetes** com suporte a service mesh (no GKE Autopilot, a flag
    `allow-net-admin`). Só o cluster é premissa — ver abaixo.
- **Implementado aqui:** a **instalação do Istio** e do **Argo CD** no cluster, o
  orquestrador (setup + promote), o Helm chart genérico, o roteamento Istio (VirtualService)
  e o ApplicationSet que descobre os papéis. *Istio e Argo CD são entregáveis do projeto,
  não premissa do cluster.*
- **Sai para outro sistema (dependência):** a automação **só escreve no gitops**. Quem
  aplica no cluster — tanto em homologação quanto em produção — é o **Argo CD** (ou outra
  solução GitOps). Na promoção, a automação apenas grava o digest homologado em
  `gitops-production`; o deploy em produção é feito pelo controlador GitOps de produção.

Detalhes completos em [Arquitetura → Fronteiras de escopo](docs/architecture.md#fronteiras-de-escopo).

---

## Documentação

- [Arquitetura](docs/architecture.md) — visão geral, componentes, fronteiras de escopo e fluxo
- [Demo local](docs/demo.md) — prova a lógica sem cluster, via `helm template`
- [Demo no cluster](docs/demo-cluster.md) — prova o roteamento Istio em runtime no GKE
- [Infra (runbook)](infra/README.md) — como subir cluster, Istio, Argo CD e ApplicationSet
- [Orquestrador](docs/orchestrator.md) — entradas, regras de negócio e simulação
- [Roteamento com Istio](docs/routing.md) — como o tráfego é desviado para a candidata
- [Argo CD e ApplicationSet](docs/argocd.md) — provisionamento e ciclo de vida via `release.yaml`
- [Pós-deploy](docs/post-deploy.md) — atualização e limpeza após deploy em produção
- [Onboarding](docs/onboarding.md) — como integrar um novo serviço
- [Decisões de design](docs/decisions.md) — registro das decisões arquiteturais

---

## Serviços de exemplo

Fluxo de 3 saltos: `checkout → wallet → ledger`.

| Serviço | Porta (compose) | Descrição |
|---------|-----------------|-----------|
| `ledger` | 8081 | Serviço de saldo. Expõe o balanço de contas. |
| `wallet` | 8082 | Carteira. Consome o `ledger` e enriquece a resposta. |
| `checkout` | 8083 | Checkout. Consome o `wallet` (que consome o `ledger`). |

---

## Começando rápido (local, sem cluster)

```bash
# serviços rodando localmente (opcional, para ver o fluxo de chamadas)
docker compose up -d --build
curl http://localhost:8083/checkout/123   # dispara checkout → wallet → ledger
docker compose down
```

Para a demo da plataforma (orquestrador + renderização dos charts), siga o roteiro
reproduzível em [docs/demo.md](docs/demo.md).

---

## Estrutura do projeto

```
staging-platform/
  services/               # serviços de exemplo (Go) + Dockerfiles
    ledger/  wallet/  checkout/
  helm/
    service-chart/        # Helm chart genérico (um chart p/ todos os papéis)
  gitops-staging/         # monorepo de homologação (fonte de verdade da hml)
    <service>/
      values.yaml         # config base (name, namespace, image, env)
      dependencies.yaml   # dependências do serviço
      clients.yaml        # clients de regressão
      staging/            # instância compartilhada (role: staging) — permanente
      candidate/          # versão em homologação (role: candidate) — efêmera
      client/for-*/       # clients de regressão por candidata — efêmero
  gitops-production/      # digests produtivos por serviço (repo separado em prod)
    <service>/release.yaml
  orchestrator/           # orquestrador (Python): setup e promote
    orchestrator.py  promote.py  manifest.py  validator.py  writer.py
  scripts/                # scripts de simulação da demo (CI, change, setup, build)
    build-images.sh  setup-gitops.sh  simulate-ci.sh  simulate-change.sh
  infra/                  # provisionamento do cluster (GKE Autopilot + Istio + Argo CD)
    01-create-cluster.md  02-install-istio.sh  03-deploy-key.md  04-install-argocd.sh
    publish-images.sh  argocd/  cleanup/
  docs/                   # arquitetura, decisões, demos e guias
  docker-compose.yaml
```

> Os manifestos de homologação (`dependencies.yaml`, `clients.yaml`) ficam no
> `gitops-staging`, não dentro de `services/`, para que o CD leia tudo de um único
> repositório. Ver [arquitetura](docs/architecture.md).

---

## Pré-requisitos

| Ferramenta | Para quê |
|------------|----------|
| Go 1.26.x | compilar os serviços |
| Docker | buildar imagens e rodar o compose |
| Helm 3.x | renderizar os charts |
| Python 3.12.x + PyYAML | rodar o orquestrador |
| gcloud · kubectl · istioctl | somente para a demo de cluster |

---

## Testando com seu próprio GCP

Os valores específicos de ambiente são parametrizados — nenhum ID de projeto real está
no repositório. Para rodar a demo de cluster no seu projeto:

1. **Exporte as variáveis** (usadas pelos scripts e documentadas nos runbooks):
   ```bash
   export PROJECT_ID=<seu-projeto-gcp>
   export REGION=us-central1
   ```
2. **Substitua o placeholder nos values do gitops.** Os `gitops-*/<svc>/values.yaml` usam
   `YOUR_GCP_PROJECT` no caminho da imagem; troque pelo seu projeto (o Argo/Helm lê esse
   valor literalmente, não expande variável de ambiente):
   ```bash
   grep -rl YOUR_GCP_PROJECT gitops-staging gitops-production \
     | xargs sed -i "s|YOUR_GCP_PROJECT|$PROJECT_ID|g"
   ```
3. Siga a [demo de cluster](docs/demo-cluster.md). O **cluster** é premissa; **Istio e
   Argo CD** são instalados pelo runbook. Ver [fronteiras de escopo](docs/architecture.md#fronteiras-de-escopo).

A demo **local** ([docs/demo.md](docs/demo.md)) não precisa de GCP e funciona com o
placeholder — ela só renderiza/manipula o gitops, sem puxar imagens.

---

## Licença / uso

Licenciado sob a [Apache License 2.0](LICENSE). PoC de referência para um case de
homologação integrada — dados são mockados e determinísticos; nenhum dado real é usado.
