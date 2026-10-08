# 01 — Cluster GKE Autopilot (PREMISSA)

> ⚠️ **Só o cluster é premissa — Istio e Argo CD são instalados pelo projeto.**
> O **cluster** GKE (com suporte a service mesh: flag `allow-net-admin`) é pré-requisito de
> ambiente, provisionado pela equipe de plataforma/infra com o mecanismo que ela preferir
> (Terraform, console, etc.). Este guia existe só para subir um cluster de **demonstração**
> rápido. **Istio** (passo 02) e **Argo CD** (passo 04) NÃO são premissa: são instalados nos
> passos seguintes deste runbook, como parte da solução. Ver
> [Fronteiras de escopo](../docs/architecture.md#fronteiras-de-escopo).

> **Variáveis:** os comandos usam `$PROJECT_ID` e `$REGION`. Exporte antes:
> ```bash
> export PROJECT_ID=<seu-projeto-gcp>
> export REGION=us-central1          # mesma região do Artifact Registry
> ```

A plataforma usa Istio OSS com injeção de sidecar. No Autopilot, isso exige a
capability `NET_ADMIN`, liberada pela política de workload `allow-net-admin`.
**Sem essa flag o Istio não injeta os sidecars** e os pods ficam quebrados.

## Opção A — gcloud (recomendado: a flag fica explícita)

```bash
gcloud container clusters create-auto staging-platform \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --autopilot-workload-policies=allow-net-admin
```

## Opção B — Console

1. Kubernetes Engine → Create → **Autopilot**
2. Nome: `staging-platform` · Região: a sua (`us-central1`)
3. Em **Advanced settings / Security** → habilite **Allow NET_ADMIN**
   (se a UI não expuser ou não gravar, habilite depois:
   `gcloud container clusters update staging-platform --location="$REGION" --autopilot-workload-policies=allow-net-admin`)

> Confirme que ficou gravado:
> ```bash
> gcloud container clusters describe staging-platform --location="$REGION" \
>   --format="value(autopilot.workloadPolicyConfig.allowNetAdmin)"   # deve imprimir True
> ```

## Obter credenciais (kubeconfig)

```bash
gcloud container clusters get-credentials staging-platform \
  --project="$PROJECT_ID" \
  --location="$REGION"

kubectl get nodes   # confirma acesso (Autopilot provisiona nós sob demanda)
```

## Custo

- Autopilot cobra pelos `requests` dos pods + taxa de gerenciamento do cluster.
- **Não** criamos ingress gateway (sem Load Balancer) — o teste de roteamento é
  mesh-interno (via `kubectl exec`/`port-forward`), evitando o maior custo pendurado.
- Ao terminar, rode `infra/cleanup/cleanup-all.sh` para destruir tudo.
