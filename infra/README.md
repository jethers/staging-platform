# Infra — Deploy da PoC no GKE Autopilot

Runbook end-to-end para subir a plataforma de homologação num cluster GKE Autopilot
com Istio OSS e Argo CD, validar o roteamento Istio em runtime, e destruir tudo.

**Projeto:** `staging-platform-510420` · **Região:** `us-central1`
**Repo (privado):** `git@github.com:jethers/staging-platform.git`

O teste é **mesh-interno** (client → candidata via sidecar) — sem ingress gateway,
sem Load Balancer. Validação por `kubectl exec`/`port-forward`.

---

## Ordem de execução

### 1. Criar o cluster
Ver `01-create-cluster.md` (gcloud ou console). **Essencial:** flag
`allow-net-admin` (sem ela o Istio não injeta sidecar no Autopilot). Depois:
```bash
gcloud container clusters get-credentials staging-platform \
  --project=staging-platform-510420 --location=us-central1
```

### 2. Instalar o Istio (sem gateway)
```bash
./02-install-istio.sh
```

### 3. Instalar o Argo CD
```bash
./04-install-argocd.sh
```

### 4. Deploy key + repo privado no Argo
Ver `03-deploy-key.md`: gerar chave, cadastrar deploy key no GitHub, criar o
Secret `repo-staging-platform` no namespace `argocd`.

### 5. Sincronizar o estado de repouso (runtime compartilhado dos 3 serviços)
```bash
kubectl apply -f argocd/staging-wallet.yaml
kubectl apply -f argocd/staging-ledger.yaml
kubectl apply -f argocd/staging-checkout.yaml
```
O Argo clona o repo e aplica os manifestos. Confirme:
```bash
kubectl get pods -n payments        # wallet, ledger, checkout (compartilhados)
```

### 6. Homologar a candidata do wallet (orquestrador → gitops → Argo)
Rode o orquestrador localmente e faça commit/push (o Argo observa `main`):
```bash
./orchestrator/simulate-jenkins.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0
git add gitops-staging && git commit -m "demo: homologa candidata do wallet" && git push
```
> Use o digest real da wallet v2.0.0 (publicado no Artifact Registry).

Aplique as Applications efêmeras:
```bash
kubectl apply -f argocd/candidate-wallet.yaml
kubectl apply -f argocd/client-checkout-for-wallet.yaml
```
Confirme que subiram `wallet-candidate`, `checkout-wallet-client` e o VirtualService:
```bash
kubectl get pods,virtualservice -n payments
```

### 7. Validar o roteamento (o coração da PoC)
O tráfego do client (`checkout-wallet-client`) deve cair na **candidata**; o tráfego
normal, no wallet **compartilhado**. Verifique pela `version` nos logs:
```bash
# dispara a cadeia a partir do pod client
kubectl exec -n payments deploy/checkout-wallet-client -c checkout -- \
  wget -qO- http://wallet:8080/wallet/123

# logs da candidata devem registrar a requisição (version da v2)
kubectl logs -n payments deploy/wallet-candidate --tail=20
# enquanto o wallet compartilhado NÃO registra essa chamada do client
kubectl logs -n payments deploy/wallet --tail=20
```

### 8. Promover (fecha o ciclo) — opcional
```bash
./orchestrator/simulate-change.sh wallet sha256:1fc69a744be805b0196bc36c5d8ecab4a0e17818a8db9370b5619ad5fe971dd0
git add gitops-staging && git commit -m "demo: promove wallet" && git push
```
O Argo faz prune das Applications efêmeras (pastas removidas pelo promote).
Remova também as Applications efêmeras do cluster:
```bash
kubectl delete -f argocd/candidate-wallet.yaml -f argocd/client-checkout-for-wallet.yaml
```

---

## Limpeza (destruir tudo)

```bash
./cleanup/cleanup-all.sh        # cluster + imagens (pede confirmação)
```
Passos manuais restantes (a saída do script lembra): remover a deploy key do GitHub,
apagar a chave SSH local e, se quiser zerar, deletar o projeto GCP.

---

## Custo — pontos de atenção

- **Autopilot**: cobra pelos requests dos pods + taxa de gerenciamento do cluster.
- **Sem ingress gateway**: evitamos Load Balancer (o maior custo pendurado).
- **Destrua após a demo**: `cleanup/cleanup-all.sh`. Confirme que não sobrou
  forwarding-rule, address ou disk órfão (comandos no fim do cleanup).
