# Roteamento com Istio

Este documento descreve como o tráfego é roteado no ambiente de homologação para que os clients de regressão exercitem a versão candidata de forma transparente, usando Istio/Envoy.

## Escopo do MVP: roteamento apenas client → candidata

No MVP, o roteamento cobre **um único caminho**: desviar os clients de regressão para a candidata. As **dependências são sempre compartilhadas** (ver decisão 19) — a candidata as chama diretamente pelo host normal, sem desvio. Não há dependências dedicadas no MVP.

Isso simplifica o roteamento e evita um problema técnico do Istio: o merge de múltiplos VirtualServices para o mesmo host **não é suportado para sidecars** (só para ingress gateway). Como o roteamento de dependência dedicada exigiria múltiplas candidatas escrevendo no VirtualService do mesmo host de dependência (concorrente), ele foi deixado fora do MVP. O roteamento client → candidata não tem esse problema (ver "Por que não há concorrência" abaixo).

## Por que Istio e não variáveis de ambiente

A alternativa mais simples seria configurar o endpoint de destino do client via variável de ambiente. Essa abordagem foi **descartada** porque:

- A plataforma não pode assumir que as aplicações externalizam os endpoints de suas dependências. Muitas podem ter o endereço **hardcoded** no código.
- O princípio da plataforma é testar a imagem **exatamente como ela vai para produção**, sem modificar código ou configuração.

O Istio resolve isso com roteamento **transparente**: o client faz a chamada para o host normal do serviço, o sidecar Envoy intercepta e redireciona para a candidata — sem o client saber.

## O VirtualService pertence ao host do serviço candidato

O VirtualService governa o host do serviço que está sendo homologado (ex.: host `wallet`), e desvia para a candidata o tráfego que vem dos clients de regressão:

```yaml
# VirtualService do host wallet (gerado pela homologação do wallet)
spec:
  hosts:
    - wallet.payments.svc.cluster.local
  http:
    - match:
        - sourceLabels:
            app: checkout-wallet-client
      route:
        - destination:
            host: wallet-candidate.payments.svc.cluster.local
    - match:
        - sourceLabels:
            app: payments-wallet-client
      route:
        - destination:
            host: wallet-candidate.payments.svc.cluster.local
    - route:
        - destination:
            host: wallet.payments.svc.cluster.local   # fallback: tráfego normal
```

- Tráfego de um client de regressão (`<client>-wallet-client`) → desviado para `wallet-candidate`
- Qualquer outro tráfego ao host `wallet` → fallback para o `wallet` compartilhado

## Um único VirtualService por candidata, sem concorrência

O VirtualService do host `wallet` é **gerado inteiro por uma única homologação** — a do wallet. Isso elimina qualquer problema de escrita concorrente ou de merge:

- **Uma candidata por serviço** (decisão 2) — só a homologação do wallet mexe no VS do host wallet.
- **Todos os clients de uma vez** — a lista de clients vem do `clients.yaml` do wallet, lido pelo orquestrador no setup. Ele gera o VS completo (todos os matches + fallback) num único objeto.
- **Sem merge de VirtualServices** — como é um único VS por host, não dependemos do merge do Istio (que não funciona para sidecars).

Contraste com o que seria a dependência dedicada: lá, o host de uma dependência (ex.: `ledger`) receberia rotas de **várias candidatas independentes** (wallet, checkout...), exigindo consolidação concorrente no mesmo VS. É justamente esse problema que o MVP evita ao não ter dependências dedicadas.

## Injeção do sidecar Istio: só quem origina desvio

O sidecar Envoy é controlado pela flag `istioInject` no values. O princípio: **só precisa de sidecar quem origina um desvio** — porque o desvio é avaliado no Envoy de quem faz a chamada.

| Role | Sidecar? | Motivo |
|------|----------|--------|
| `staging` | **Não** | Serviço compartilhado, fora do mesh |
| `candidate` | **Não** (no MVP) | Só chama dependências compartilhadas (direto) e recebe tráfego dos clients |
| `client` | **Sim** | Origina o desvio para a candidata — avalia o `sourceLabels` no seu Envoy |

No MVP, **só os clients têm sidecar**. A candidata não origina desvio (suas dependências são compartilhadas, chamadas diretas), então não precisa de sidecar. O chart injeta a annotation `sidecar.istio.io/inject` apenas quando `istioInject: true`; o orquestrador seta a flag só para os clients (ver decisão 11).

Sem mTLS obrigatório (fora do escopo do MVP; mesh em PERMISSIVE), um client com sidecar chama a candidata sem sidecar normalmente.

## O Service da candidata

A candidata tem seu próprio Service (`wallet-candidate`), renderizado pelo mesmo chart genérico a partir da config comum da base. É **idêntico ao Service do staging** — mesma porta, protocolo e config — diferindo em:

- **Nome:** `wallet-candidate` (em vez de `wallet`)
- **Selector:** `app: wallet-candidate` — roteia para os pods da candidata

Isso é o que permite ao VirtualService desviar o tráfego dos clients para `wallet-candidate` — o destino tem o mesmo contrato de rede do serviço original, só aponta para a versão candidata.

## O Service compartilhado vem do onboarding

O Service do serviço compartilhado existe sempre no `staging/` (via onboarding), mesmo sem runtime. É ele o host (`wallet`) que o VirtualService governa e o alvo do fallback. O `staging/release.yaml` com digest vazio renderiza só o Service, sem Deployment (ver decisão 10).

## Ordem de provisionamento

Enquanto o ambiente é provisionado, erros transitórios são **esperados e aceitáveis**. Se o VirtualService apontar para a candidata antes dela subir, o Envoy retorna um 503 temporário que se resolve sozinho assim que a candidata fica pronta. Nada fica num estado quebrado permanente:

- Candidata e clients são Deployments de longa duração que se auto-recuperam.
- Kubernetes e Istio são eventualmente consistentes.
- Os testes de integração só rodam **depois** que o orquestrador confirma `Synced/Healthy`.

Por isso não há necessidade de ordenar o provisionamento (ex.: sync waves). A garantia vem do fluxo da pipeline: só exercitar o tráfego de teste após o ambiente reportar estado saudável.

## Evolução futura

- **Dependências dedicadas** — exigiriam resolver o roteamento candidata → dependência (VS no host da dependência, com consolidação de rotas de múltiplas candidatas). Como o merge de VirtualServices não funciona para sidecars, isso demandaria o orquestrador consolidar um VS único por host de dependência, com controle de concorrência entre homologações que compartilham a mesma dependência. Fica fora do MVP (baixo valor + alto custo, ver decisão 19).
- **Roteamento por header** — permitiria clients compartilhados (em vez de dedicados), desviando com base num header de contexto de teste propagado entre serviços (ver decisão 8).
