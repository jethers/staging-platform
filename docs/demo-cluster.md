# Roteiro de Demo — No Cluster (GKE + Istio + Argo CD)

Esta é a demo **em runtime**: prova o comportamento central da plataforma — o Istio
desviando o tráfego real do client de regressão para a candidata — num cluster GKE
Autopilot de verdade. Complementa a demo local ([`demo.md`](demo.md)), que prova a
lógica sem cluster via `helm template`.

**Projeto:** `staging-platform-510420` · **Região:** `us-central1`
**Repo (privado):** `git@github.com:jethers/staging-platform.git`

O setup detalhado de cada componente está em [`../infra/README.md`](../infra/README.md);
aqui o foco é a **narrativa da demonstração** e as validações que provam o roteamento.

> ⚠️ **Custo:** o cluster Autopilot cobra enquanto estiver no ar. Ao terminar, destrua
> tudo com `./infra/cleanup/cleanup-all.sh`.

---

## Pré-requisitos (ferramentas no WSL)

| Ferramenta | Para quê |
|------------|----------|
| gcloud (autenticado) | criar cluster, Artifact Registry, credenciais |
| kubectl + gke-gcloud-auth-plugin | falar com o cluster |
| istioctl | instalar o Istio |
| docker | buildar as imagens |
| gh (autenticado) | cadastrar a deploy key |

---

## Bloco 0 — Imagens no Artifact Registry

O GKE puxa as imagens por digest do Artifact Registry. Primeiro buildar, depois publicar.

```bash
./scripts/build-images.sh      # builda ledger v1, wallet v1, wallet v2, checkout v1
./infra/publish-images.sh      # cria o repo docker-images (us-central1) e dá push
```

**O que prova:** as 4 imagens ficam disponíveis em
`us-central1-docker.pkg.dev/staging-platform-510420/docker-images/<svc>`, com os digests
que os `release.yaml` do gitops referenciam.

---

## Bloco 1 — Subir a infraestrutura

Ver [`../infra/README.md`](../infra/README.md) para o detalhe. Em resumo:

```bash
# 1. Cluster Autopilot — ESSENCIAL a flag allow-net-admin (senão o Istio não injeta sidecar)
gcloud container clusters create-auto staging-platform \
  --project=staging-platform-510420 --location=us-central1 \
  --autopilot-workload-policies=allow-net-admin
gcloud container clusters get-credentials staging-platform \
  --project=staging-platform-510420 --location=us-central1

# 2. Istio sem CNI (no Autopilot o CNI exige SYS_ADMIN, indisponível; usa-se istio-init)
./infra/02-install-istio.sh

# 3. Argo CD
./infra/04-install-argocd.sh

# 4. Deploy key SSH read-only + Secret do repo no Argo (ver infra/03-deploy-key.md)

# 5. ApplicationSet (descobre os papéis via glob **/release.yaml)
kubectl apply -f infra/argocd/applicationset.yaml
```

**Esperado (estado de repouso):** o ApplicationSet gera 3 Applications (staging de
wallet, ledger, checkout) e os 3 pods sobem `2/2` (app + sidecar Istio) no namespace
`payments`:
```bash
kubectl get applications -n argocd
kubectl get pods -n payments
```

---

## Bloco 2 — Homologar a candidata do wallet

Aciona o orquestrador (via o script de simulação do Jenkins) e faz commit/push. O Argo
observa `main` e o ApplicationSet detecta as novas pastas.

```bash
./scripts/simulate-jenkins.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0
git add gitops-staging && git commit -m "demo: homologa candidata do wallet" && git push
```

Force o Argo a reescanear (ou aguarde o ciclo de ~3min):
```bash
kubectl rollout restart deploy/argocd-repo-server -n argocd
kubectl -n argocd annotate applicationset homologacao argocd.argoproj.io/refresh=hard --overwrite
```

**Esperado:** o ApplicationSet passa a gerar **5 Applications** (surgem `wallet-candidate`
e `checkout-wallet-client`), e os pods efêmeros sobem:
```bash
kubectl get applications -n argocd
kubectl get pods,virtualservice -n payments
# espera-se wallet-candidate, checkout-wallet-client e o VirtualService wallet-candidate-routes
```

---

## Bloco 3 — Validar o roteamento Istio (o coração da demo)

A regra: tráfego originado do `checkout-wallet-client` é desviado para a **candidata (v2)**;
qualquer outra origem vai para o **wallet compartilhado (v1)**. Distinguimos pela `version`.

### 3.1 Versões de cada wallet

```bash
kubectl exec -n payments deploy/wallet -c wallet -- wget -qO- http://localhost:8080/wallet/123
# version: v1.0.0
kubectl exec -n payments deploy/wallet-candidate -c wallet -- wget -qO- http://localhost:8080/wallet/123
# version: v2.0.0-candidate
```

### 3.2 Tráfego do CLIENT → deve cair na candidata v2

```bash
kubectl exec -n payments deploy/checkout-wallet-client -c checkout -- \
  wget -qO- http://wallet:8080/wallet/123
```
**Esperado:** `"version":"v2.0.0-candidate"`. A chamada parte de dentro do pod client,
então passa pelo sidecar Envoy dele — que tem a regra de desvio.

### 3.3 Tráfego de OUTRA origem → deve cair no compartilhado v1

```bash
kubectl exec -n payments deploy/ledger -c ledger -- wget -qO- http://wallet:8080/wallet/123
```
**Esperado:** `"version":"v1.0.0"`. Sem o label de client, o Envoy não desvia.

### 3.4 Prova no nível do Envoy (não só comportamento)

Confirma que foi o Envoy que roteou, inspecionando a config que cada sidecar carregou:

```bash
CLIENT_POD=$(kubectl get pod -n payments -l app=checkout-wallet-client -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config routes "$CLIENT_POD.payments" --name 8080 -o json | \
  grep -A2 '"wallet.payments'
```
**Esperado:** no Envoy do **client**, o host `wallet...` aponta para o cluster
`...wallet-candidate...`. Num pod não-client (ex: `ledger`), o mesmo host aponta para
`...wallet...` (compartilhado). Mesma requisição, destinos diferentes conforme a origem.

### 3.5 Ver nos logs da candidata

```bash
kubectl logs -n payments deploy/wallet-candidate -c wallet -f
# em outro terminal, dispare o 3.2 — as requisições aparecem aqui com version=v2.0.0-candidate
```

---

## Bloco 4 — Change / promote (fecha o ciclo)

Condensa o Job 2: atualiza produção com o digest v2 e roda o promote (espelha no
compartilhado + remove efêmeros).

```bash
./scripts/simulate-change.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0
git add gitops-staging gitops-production && git commit -m "demo: promove wallet v2" && git push
```

Force o reescaneamento e observe o Argo fazer **prune automático** dos efêmeros:
```bash
kubectl rollout restart deploy/argocd-repo-server -n argocd
kubectl -n argocd annotate applicationset homologacao argocd.argoproj.io/refresh=hard --overwrite
```

**Esperado:**
- O ApplicationSet volta a gerar **3 Applications** (as efêmeras somem).
- Os pods `wallet-candidate` e `checkout-wallet-client` são removidos; o VirtualService some.
- O `wallet` compartilhado é recriado na **v2**:
```bash
kubectl get applications -n argocd
kubectl get pods,virtualservice -n payments
kubectl exec -n payments deploy/wallet -c wallet -- wget -qO- http://localhost:8080/wallet/123
# version: v2.0.0-candidate  (o compartilhado agora roda a v2 promovida)
```

Esse é o fechamento do ciclo GitOps: o promote removeu as pastas do git, o ApplicationSet
detectou e fez prune, o Argo removeu os pods, o compartilhado reconciliou para a nova versão.

---

## Limpeza (destruir tudo — para o custo)

```bash
./infra/cleanup/cleanup-all.sh        # cluster + imagens (pede confirmação)
```
Passos manuais restantes (a saída lembra): remover a deploy key do GitHub e, se quiser
zerar, apagar a chave SSH local e o projeto GCP. Confira resíduos de rede:
```bash
gcloud compute forwarding-rules list --project=staging-platform-510420
gcloud compute addresses list --project=staging-platform-510420
gcloud compute disks list --project=staging-platform-510420
```

---

## Checklist da demo de cluster

- [ ] Imagens buildadas e publicadas no Artifact Registry (Bloco 0)
- [ ] Cluster criado com `allow-net-admin`; Istio sem CNI; Argo CD no ar (Bloco 1)
- [ ] ApplicationSet gera os 3 staging; pods `2/2` com sidecar (Bloco 1)
- [ ] Homologação: ApplicationSet gera candidata + client automaticamente (Bloco 2)
- [ ] Tráfego do client → candidata v2 (Bloco 3.2)
- [ ] Tráfego de outra origem → compartilhado v1 (Bloco 3.3)
- [ ] Config do Envoy confirma o desvio (Bloco 3.4)
- [ ] Promote: produção v2, prune automático dos efêmeros, compartilhado em v2 (Bloco 4)
- [ ] Cluster e imagens destruídos; sem resíduos de rede (Limpeza)
