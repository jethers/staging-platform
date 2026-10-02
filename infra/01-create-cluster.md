# 01 — Criar o cluster GKE Autopilot

> Passo manual (console ou gcloud). Região **us-central1** (mesma do Artifact Registry).

A plataforma usa Istio OSS com injeção de sidecar. No Autopilot, isso exige a
capability `NET_ADMIN`, liberada pela política de workload `allow-net-admin`.
**Sem essa flag o Istio não injeta os sidecars** e os pods ficam quebrados.

## Opção A — gcloud (recomendado: a flag fica explícita)

```bash
gcloud container clusters create-auto staging-platform \
  --project=staging-platform-510420 \
  --location=us-central1 \
  --workload-policies=allow-net-admin
```

## Opção B — Console

1. Kubernetes Engine → Create → **Autopilot**
2. Nome: `staging-platform` · Região: `us-central1`
3. Em **Advanced settings / Security** → habilite **Allow NET_ADMIN**
   (se a UI não expuser, crie e rode depois:
   `gcloud container clusters update staging-platform --location=us-central1 --enable-workload-policies=allow-net-admin`)

## Obter credenciais (kubeconfig)

```bash
gcloud container clusters get-credentials staging-platform \
  --project=staging-platform-510420 \
  --location=us-central1

kubectl get nodes   # confirma acesso (Autopilot provisiona nós sob demanda)
```

## Custo

- Autopilot cobra pelos `requests` dos pods + taxa de gerenciamento do cluster.
- **Não** criamos ingress gateway (sem Load Balancer) — o teste de roteamento é
  mesh-interno (via `kubectl exec`/`port-forward`), evitando o maior custo pendurado.
- Ao terminar, rode `infra/cleanup/cleanup-gcp.sh` para destruir tudo.
