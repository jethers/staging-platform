# Decisões de Design

Registro das principais decisões arquiteturais tomadas durante o desenvolvimento da plataforma.

---

## 1. Releases independentes como padrão

**Decisão:** cada serviço homologa e publica de forma autônoma. Releases coordenadas são usadas apenas para mudanças incompatíveis ou de alto risco.

**Motivação:** preservar a autonomia das squads e a agilidade no deploy. Releases coordenadas criam filas e dependências entre times.

**Mitigação dos riscos:** retrocompatibilidade de APIs, feature flags, testes de contrato, canary deployment e a própria plataforma de homologação integrada.

---

## 2. Uma candidata por serviço por vez

**Decisão:** no máximo uma versão candidata de cada serviço pode estar em homologação simultaneamente.

**Motivação:** simplifica o roteamento, o provisionamento e o gerenciamento do ambiente. Múltiplas candidatas simultâneas exigiriam identificadores dinâmicos em todos os recursos Kubernetes e aumentariam significativamente a complexidade.

**Consequência positiva:** cria pressão natural para deploys frequentes e pequenos, o que reduz risco em produção.

---

## 3. Dependências e consumidores na versão produtiva vigente

**Decisão:** a candidata é sempre testada num ambiente produtivo vigente, nunca contra outras candidatas. Isso vale para os dois lados do grafo de chamadas:

- **Dependências** (serviços que a candidata chama) rodam na versão produtiva vigente.
- **Consumidores / clients de regressão** (serviços que chamam a candidata) também rodam na versão produtiva vigente, exercitando a candidata como ela seria chamada em produção.

**Motivação:** simular o ambiente que a candidata encontrará em produção, de ambos os lados. Testar contra outras candidatas introduziria variáveis desconhecidas e tornaria os resultados menos confiáveis.

**Dependências:** no MVP, todas resolvem para o serviço compartilhado (`staging`) — chamada direta, sem desvio. Dependências dedicadas (isoladas por candidata) ficam fora do MVP (ver decisão 19).

---

## 4. gitops-production como fonte de verdade dos digests produtivos

**Decisão:** o orquestrador busca os digests das dependências no repositório `gitops-production`, não diretamente no cluster de produção.

**Motivação:** desacopla a plataforma de homologação do mecanismo de deploy de produção. O `gitops-production` funciona como um registro — qualquer CD de produção pode atualizá-lo ao finalizar um deploy.

**Restrição:** dependência ou client sem digest registrado em `gitops-production` resulta em erro explícito. O ciclo de homologação não prossegue.

---

## 5. Bootstrap manual do digest produtivo para serviços existentes

**Decisão:** serviços que já estavam em produção antes da adoção da plataforma têm seu digest produtivo registrado manualmente no `gitops-production/<service>/release.yaml` (uma única vez).

**Escopo:** esse registro no `gitops-production` é necessário para **todo serviço envolvido nos testes** — a candidata, suas dependências e seus clients — porque o orquestrador lê esse digest para provisionar dependências dedicadas e clients na versão produtiva. É uma informação sobre "o que está em produção", **independente** de o serviço ter ou não runtime (pods) rodando em homologação. Um serviço pode ter digest produtivo registrado e, ao mesmo tempo, estar em homologação apenas como host no mesh (staging com digest vazio) — são coisas distintas.

**Não confundir com o onboarding do `gitops-staging`** (decisão 20): o `gitops-production` registra a versão produtiva; o `gitops-staging` define a estrutura de homologação (values base + staging/). Ambos são pré-requisitos, mas em repositórios e com propósitos diferentes.

**Motivação:** evitar que a adoção da plataforma force um re-deploy de todos os serviços existentes. O onboarding deve ser gradual e não disruptivo.

**Processo:** após o registro manual, o serviço segue o fluxo normal — cada novo deploy em produção atualiza o `gitops-production` automaticamente.

---

## 6. `release.yaml` separado dos `values.yaml`

**Decisão:** o digest da imagem fica em um arquivo `release.yaml` separado dos demais valores de configuração.

**Motivação:** o digest é o único campo alterado pelo orquestrador a cada ciclo. Isolá-lo facilita diffs, revisões e automação — a automação modifica apenas `release.yaml`, nunca `values.yaml`.

---

## 7. Helm Chart genérico com hierarquia de values

**Decisão:** um único chart genérico serve para todos os serviços. A especialização é feita via arquivos de values em camadas: `values.yaml` (base) → `<ambiente>/values.yaml` (overrides) → `<ambiente>/release.yaml` (digest).

**Motivação:** reduz duplicação, facilita manutenção e garante consistência entre serviços. Novos serviços precisam apenas de seus arquivos de values — nenhum código de chart precisa ser escrito.

---

## 8. Roteamento via Istio, não via variáveis de ambiente

**Decisão:** o desvio de tráfego para candidatas e dependências dedicadas é feito por roteamento transparente do Istio (VirtualService + `sourceLabels`), não por configuração de endpoint em variável de ambiente.

**Motivação:** a plataforma não pode assumir que as aplicações externalizam os endpoints de suas dependências — muitas podem tê-los hardcoded. O Istio intercepta a chamada no sidecar sem exigir qualquer alteração no código ou configuração da aplicação, preservando o princípio de testar a imagem exatamente como vai para produção.

**Trade-off adiado:** roteamento por header (propagação de contexto de teste) é mais flexível mas exige que as aplicações propaguem o header entre si. Fica para uma versão futura.

---

## 9. VirtualService pertence ao host do serviço candidato

**Decisão:** no MVP, o VirtualService governa o host do serviço que está sendo homologado (ex.: host `wallet`) e desvia para a candidata (`wallet-candidate`) o tráfego que vem dos clients de regressão. É o único caminho de roteamento (client → candidata); dependências são sempre compartilhadas, sem desvio (ver decisão 19).

**Motivação:** é o host compartilhado que o client chama (o client não sabe que testa a candidata). O VirtualService intercepta esse tráfego e desvia pela origem (`sourceLabels` do client). Fica junto do Service compartilhado no `staging/`, que é permanente e é o alvo do fallback.

**Sem concorrência:** o VirtualService do host `wallet` é gerado inteiro por uma única homologação — a do wallet. Como só há **uma candidata por serviço** (decisão 2) e todos os clients vêm do `clients.yaml` (lido de uma vez pelo orquestrador), o VS é escrito por um único dono, com todas as rotas + fallback num só objeto. Não há merge de VirtualServices (que o Istio não suporta para sidecars) nem escrita concorrente. Era justamente o roteamento candidata → dependência (removido no MVP) que teria concorrência, por um host de dependência ser alvo de várias candidatas.

---

## 10. Service compartilhado sempre presente em staging; Deployment condicional

**Decisão:** o `staging/` de cada serviço sempre renderiza o Service (o host do mesh), mesmo sem pods. O Deployment em staging é renderizado apenas quando há versão compartilhada ativa (digest preenchido em `staging/release.yaml`).

**Motivação:** o VirtualService precisa de um host válido no mesh, o que exige o Service existente. Nem todo serviço precisa de pods permanentes em staging, mas todos precisam do Service para serem alvo de roteamento.

---

## 11. Injeção do sidecar Istio controlada por flag, não por namespace

**Decisão:** o sidecar Envoy é injetado por pod, controlado por uma flag `istioInject` no values (default `false`). O chart tem uma regra única: injeta a annotation `sidecar.istio.io/inject` apenas quando `istioInject: true`. Quem decide o valor da flag é o orquestrador, conforme o papel do pod no roteamento:

| Role | `istioInject` | Motivo |
|------|---------------|--------|
| `staging` | `false` | Serviço compartilhado, fora do mesh — chamadas diretas |
| `candidate` | `false` (no MVP) | Só chama dependências compartilhadas (direto) e recebe tráfego dos clients; não origina desvio |
| `client` | `true` | Origina o desvio para a candidata — avalia o `sourceLabels` no seu Envoy |

**Princípio:** só precisa de sidecar quem **origina um desvio** (o desvio é avaliado no Envoy de quem faz a chamada). No MVP, só os **clients** originam desvio (para a candidata); a candidata chama suas dependências compartilhadas diretamente, sem desvio, então não precisa de sidecar. Minimizar os sidecars minimiza a superfície do mesh. Sem mTLS obrigatório (fora do escopo do MVP; mesh em modo PERMISSIVE), um client com sidecar chama a candidata sem sidecar normalmente.

**Por que flag e não derivar do role:**
- Mantém o chart com uma regra única (lê a flag); toda a lógica de "quem precisa" fica no orquestrador.
- **Compatibilidade futura:** se dependências dedicadas forem reintroduzidas, a candidata passaria a originar desvio e precisaria de sidecar — bastaria o orquestrador setar a flag, sem mudar o chart. O mesmo vale para roteamento por header (decisão 8).

**Injeção por namespace foi descartada:** colocaria os serviços compartilhados (mesmo namespace) no mesh desnecessariamente.

---

## 12. Ordem de provisionamento não é requisito de corretude

**Decisão:** não impor ordenação no provisionamento (ex.: Argo CD sync waves). Erros transitórios durante o setup do ambiente são aceitáveis.

**Motivação:** candidata, dependências e clients são Deployments de longa duração que se auto-recuperam; o Kubernetes e o Istio são eventualmente consistentes. Um 503 enquanto um destino ainda sobe se resolve sozinho. A única garantia necessária vem do fluxo da pipeline: os testes só rodam após o ambiente reportar `Synced/Healthy`. Ordenação seria, no máximo, um refinamento opcional de higiene — não um requisito. Preocupação com ordem só se justificaria se algo quebrasse de forma irrecuperável sem intervenção manual, o que não é o caso.

---

## 13. VirtualService apenas quando há rota de desvio

**Decisão:** não criar VirtualService por padrão para todos os serviços. O VirtualService de um serviço só existe quando ele tem uma candidata em homologação com ao menos um client de regressão (há tráfego a desviar).

**Motivação:** um VirtualService com apenas a rota de fallback (host → mesmo host) é inócuo — replica o que o Kubernetes já faz sem Istio. O que sempre precisa existir é o Service (host do mesh), não o VirtualService. O VirtualService é efêmero: existe enquanto a candidata está em homologação e some quando a candidata é removida na limpeza. O Service, por sua vez, permanece (decisões 10 e 18).

---

## 14. VirtualService da candidata gerado de uma vez, sem merge entre recursos

**Decisão:** o VirtualService do host de um serviço candidato é um **único objeto**, gerado a partir dos values da candidata (que incluem a lista de clients de regressão, vinda do `clients.yaml`). Contém todas as rotas dos clients + o fallback, num só VirtualService. Não se usa merge de múltiplos VirtualServices para o mesmo host.

**Motivação:** o Istio **não suporta merge de VirtualServices para o mesmo host em sidecars** (só em ingress gateway) — a ordem de rotas entre recursos não é garantida. Portanto, todas as rotas de um host precisam estar num único VirtualService. Isso é viável sem concorrência porque há **uma candidata por serviço** (decisão 2): a homologação daquele serviço é a única dona do VS do host, e gera todas as rotas de uma vez a partir do `clients.yaml`. O orquestrador escreve os valores da candidata (incluindo a lista de clients); o chart renderiza o VirtualService completo.

---

## 15. Monorepo para gitops-staging

**Decisão:** todos os manifestos de homologação ficam num único repositório (`gitops-staging`). O `gitops-production` permanece separado.

**Motivação:** manter todos os serviços de homologação numa árvore única simplifica o CD (um ApplicationSet, um repositório a observar) e o versionamento conjunto do ambiente. Produção fica separada por isolamento de segurança e ciclo de vida próprio.

---

## 16. ApplicationSet com file generator; `release.yaml` como gatilho de existência

**Decisão:** um único ApplicationSet monitora todos os `release.yaml` do `gitops-staging` via Git file generator. Cada `release.yaml` gera uma Application. A presença/ausência do arquivo controla a existência da Application.

**Motivação:** torna a limpeza dos efêmeros trivial — remover o `release.yaml` deleta a Application e, com prune, remove os recursos do cluster. Centraliza o provisionamento num único objeto declarativo, sem precisar criar/deletar Applications manualmente.

---

## 17. Deployment condicional ao digest; prune como requisito

**Decisão:** o chart renderiza o Deployment apenas quando o `release.yaml` tem digest; o Service é sempre renderizado. O prune automático é habilitado no ApplicationSet.

**Motivação:** o prune é necessário para a destruição efetiva — sem ele, remover arquivos deixaria recursos órfãos no cluster. O prune é isolado por Application, sem risco global.

**Dois comportamentos distintos:**

- **Staging compartilhado** — nunca é destruído por completo. Esvaziar o digest remove apenas o Deployment (pods eliminadas), mas preserva o Service, porque o Service nunca sai do manifesto renderizado e o prune só age sobre o que sai do Git. O staging é permanente como host no mesh.
- **Efêmeros (candidate, dependency, client)** — destruídos por completo. Remover o `release.yaml` deleta a Application inteira, e o prune remove todos os recursos daquele app do cluster (Deployment, Service e VirtualService). Não resta nada do efêmero.

---

## 18. Staging deve existir via onboarding; o orquestrador não o cria

**Decisão:** o orquestrador **não cria** a pasta `staging/` de nenhum serviço. Todo serviço usado como dependência (ou candidata/client) deve ter seu `staging/` já criado no onboarding, com `release.yaml` (digest vazio quando não há runtime compartilhado). Se o `staging/` não existir, o orquestrador falha com erro explícito.

**Motivação:** criar o `staging/` sob demanda tornava o orquestrador complexo — ele passaria a escrever estrutura em serviços que não são o alvo da homologação. Exigir o `staging/` no onboarding mantém o orquestrador simples: ele só valida existência e escreve nos arquivos da própria homologação (candidata, suas dependências dedicadas e clients). O Service compartilhado (host do mesh) é garantido pelo onboarding, não pela automação.

**Preservação:** o `staging/` com digest vazio (só Service, sem runtime) é um estado válido e permanente. Promover o serviço a compartilhado real é apenas preencher o digest.

---

## 19. Dependências sempre compartilhadas no MVP (sem dependência dedicada)

**Decisão:** no MVP, todas as dependências de uma candidata são **compartilhadas** — a candidata as chama diretamente no host normal (que resolve para o `staging/` da dependência). Não há dependência dedicada. O `dependencies.yaml` é uma lista simples de nomes:

```yaml
app: wallet
dependencies:
  - ledger
  - antifraud
```

**Motivação (baixo valor + alto custo):**

- **Baixo valor:** o isolamento que a dependência dedicada traria não se justifica. Isolamento de estado é responsabilidade do próprio teste (gestão de dados de teste, cleanup). Isolamento para teste de carga seria ilusório — como as dependências transitivas continuam compartilhadas, a carga vazaria para elas de qualquer forma; isolar a cadeia inteira recursivamente explodiria custo e complexidade.
- **Alto custo técnico:** a dependência dedicada exigiria rotear o tráfego candidata → dependência dedicada via VirtualService no host da dependência. Como um host de dependência (ex.: `ledger`) pode ser alvo de **várias candidatas independentes** (wallet, checkout...), seria preciso consolidar múltiplas rotas no mesmo VirtualService. E o Istio **não suporta merge de VirtualServices para o mesmo host em sidecars** (só em ingress gateway) — exigiria um VS único consolidado por host, com escrita concorrente entre homologações paralelas. Complexidade alta para um ganho que não se justifica.

**Consequências da simplificação:**
- `dependencies.yaml` é lista simples (sem `mode`)
- Sem pastas `dependency/for-*/`
- A candidata não origina desvio → **não precisa de sidecar** (ver decisão 11)
- O roteamento cobre só o caminho client → candidata (ver decisão 9), que não tem o problema de concorrência (uma candidata por serviço, um VS por host de candidato)

**Evolução futura:** dependências dedicadas poderiam ser reintroduzidas se um caso concreto exigir, resolvendo o roteamento candidata → dependência com um VS consolidado por host (orquestrador consolida, com controle de concorrência entre homologações que compartilham a dependência). Clients compartilhados dependeriam de roteamento por header (ver decisão 8). Ambos ficam fora do MVP.

---

## 20. Onboarding: config permanente (base, staging, dependencies, clients)

**Decisão:** o onboarding de um serviço cria apenas a parte **permanente** no `gitops-staging`:

```
<service>/
  values.yaml          # base (identidade do serviço)
  dependencies.yaml    # relação de dependências (com modo de cada uma)
  clients.yaml         # relação de clients de regressão
  staging/
    values.yaml        # role: staging
    release.yaml       # digest (vazio quando não há runtime compartilhado)
```

A pasta `candidate/` **não** faz parte do onboarding — é efêmera, criada pelo orquestrador quando a homologação é disparada (ver decisão 25).

**Motivação:** o orquestrador não pode inventar dados fundamentais de um serviço (namespace, image.repository, service.port) nem a estrutura de staging — vêm do onboarding. Os manifestos `dependencies.yaml` e `clients.yaml` ficam na raiz (permanente), não dentro de `candidate/`, para que a relação de dependências/clients sobreviva à remoção da candidata na limpeza. O orquestrador verifica só a **existência** dos arquivos; se incompletos, o Helm falha na renderização e o Argo CD reporta.

**O que o orquestrador cria** (quando o serviço está onboardado): a pasta `candidate/` (values + release) e as pastas `client/for-<candidate>/` dos clients de regressão. **O que não cria:** o `values.yaml` base, `dependencies.yaml`, `clients.yaml` e o `staging/` — sua ausência é erro explícito "serviço não onboardado".

---

## 21. Namespace obrigatório, sem default

**Decisão:** o `namespace` deve vir explicitamente do `values.yaml` base de cada serviço. Não há valor default — nem no chart (placeholder vazio), nem no orquestrador (`load_namespace` lança erro se vazio).

**Motivação:** o namespace faz parte do endereço de rede no mesh (`<service>.<namespace>.svc.cluster.local`). Um default silencioso (ex.: `default`) mascararia erro de configuração e provisionaria recursos no namespace errado, causando falha de roteamento difícil de diagnosticar. Falhar cedo e explicitamente é mais seguro.

---

## 22. staging/release.yaml com digest vazio é um estado válido

**Decisão:** um `staging/release.yaml` com digest vazio (criado no onboarding) é um estado válido e permanente: o chart renderiza só o Service (host do mesh), sem Deployment.

**Motivação:** um serviço pode existir no mesh apenas como host (alvo do fallback de uma candidata, ou simplesmente registrado) sem ter runtime compartilhado. O digest vazio expressa isso. No MVP, como as dependências são compartilhadas (decisão 19), uma dependência precisa ter runtime ativo (digest preenchido) para a candidata consumi-la; o orquestrador valida isso e produz erro acionável se o staging da dependência estiver vazio.

---

## 23. Duas camadas: ApplicationSet controla existência, Application reconcilia conteúdo

**Decisão:** o ApplicationSet monitora os `release.yaml` apenas para controlar **quais Applications existem**. Cada Application gerada aponta para o diretório do serviço e lê todos os valueFiles (base + role + release), reconciliando qualquer mudança neles.

**Motivação:** separa os dois papéis sem conflito. O `release.yaml` é gatilho de existência para o ApplicationSet e, ao mesmo tempo, um dos valueFiles reconciliados pela Application. Mudanças em qualquer values (namespace, imagem, env, digest) são refletidas no cluster pela Application; criação/remoção de instâncias é controlada pelo ApplicationSet via presença do `release.yaml`.

---

## 24. Namespace via manifesto (metadata.namespace), não via destination

**Decisão:** o namespace vem do `values.yaml` base e é renderizado pelo chart em `metadata.namespace` de cada recurso. Os namespaces de homologação são criados previamente (Terraform/manifesto base).

**Motivação:** o chart é próprio e já tem o namespace nos values — colocá-lo no manifesto é trivial e mantém uma fonte única. Evita o ApplicationSet ter que parsear o `values.yaml` só para popular `destination.namespace`. A alternativa (`destination.namespace` + `CreateNamespace=true`), que criaria namespaces sob demanda, fica como evolução futura se necessário. Para o MVP, com poucos namespaces fixos, criação prévia é suficiente.

---

## 25. Candidate, dependency e client são efêmeros; a limpeza remove a pasta inteira

**Decisão:** as pastas `candidate/` e `client/for-<candidate>/` são **efêmeras** — criadas pelo orquestrador no setup da homologação e removidas por inteiro na limpeza pós-deploy. Regra única: a limpeza remove a pasta inteira de qualquer efêmero. O que permanece (via onboarding) é a config permanente na raiz: `values.yaml` base, `dependencies.yaml`, `clients.yaml` e `staging/`. (Com a reintrodução de dependências dedicadas no futuro, as pastas `dependency/for-<candidate>/` seguiriam a mesma regra.)

**Setup é idempotente (cobre primeira vez e rebuild):** ao disparar o setup, o orquestrador garante o estado desejado de cada pasta efêmera:
- pasta ausente → cria `values.yaml` (role/target) + `release.yaml` (digest)
- pasta existente (ex.: rebuild da imagem durante a mesma homologação) → sobrescreve apenas o `release.yaml` com o novo digest; o `values.yaml` permanece

Como o Git só gera commit se o arquivo mudar, reaplicar o setup com o mesmo digest não causa efeito.

**Motivação:**

- **Evitar ambiguidade de estado:** se as pastas fossem preservadas, a cada nova candidata o orquestrador teria que decidir "sobrescrevo ou mantenho a config existente?" — reintroduzindo a reconciliação de estado pré-existente que a plataforma evita. Removendo a pasta inteira, cada homologação começa do zero: a pasta nasce e morre com a homologação.
- **A relação de dependências/clients não se perde:** `dependencies.yaml` e `clients.yaml` ficam na raiz (permanente, via onboarding), não em `candidate/`. Por isso a candidata pode ser removida por inteiro sem perder essa informação — foi o que motivou tirá-los de dentro de `candidate/`.
- **Recriação é trivial:** o `values.yaml` de cada pasta efêmera é mínimo (`role` + `target`, herdando a base — ver decisão 26). O orquestrador recria sem esforço.

Nota: customizações manuais no `values.yaml` de uma pasta efêmera não são duráveis — a limpeza remove a pasta. Ajustes que precisem persistir devem ir na base do serviço (`<service>/values.yaml`), ou ser tratados como evolução futura (overrides persistentes por situação).

---

## 26. Divisão entre config comum (raiz) e específica de cada situação

**Decisão:** o `values.yaml` na raiz do serviço (`<service>/values.yaml`) contém a configuração **comum às quatro situações** (staging, candidate, dependency, client) — a identidade do serviço. Cada situação tem um `values.yaml` próprio apenas com o que a diferencia.

As quatro situações estão no mesmo nível conceitual: `staging/` não é especial, é só uma delas. Todas herdam o `values.yaml` da raiz.

**Comum (raiz, `<service>/values.yaml`):**

```yaml
name: <service>
namespace: <namespace>
image:
  repository: <org>/<service>
  pullPolicy: IfNotPresent
service:
  port: <port>
env:
  - name: PORT
    value: "<port>"
resources:
  requests: { cpu: ..., memory: ... }
  limits: { cpu: ..., memory: ... }
replicaCount: 1
```

**Específico de cada situação (`<situação>/values.yaml`):**

| Situação | Campos próprios |
|----------|-----------------|
| `staging/` | `role: staging` |
| `candidate/` | `role: candidate` |
| `client/for-<candidate>/` | `role: client`, `target: <candidate>` |
| `dependency/for-<candidate>/` (futuro) | `role: dependency`, `target: <candidate>` |

No MVP só existem as três primeiras situações (dependências são compartilhadas — decisão 19). O chart suporta o role `dependency` para quando dependências dedicadas forem reintroduzidas. O `image.digest` nunca fica no `values.yaml` — vem sempre do `release.yaml` de cada situação (decisão 6).

**Hierarquia de valueFiles na Application** (cascata, último vence):

```
<service>/values.yaml            # comum
<service>/<situação>/values.yaml # overrides (role, target)
<service>/<situação>/release.yaml # digest
```

**Motivação:** a identidade do serviço (nome, namespace, imagem, porta) é a mesma independente da situação — definindo-a uma vez na raiz, evita-se duplicação e divergência entre as situações. Cada situação carrega só o mínimo que a distingue.

**O que o orquestrador escreve ao criar `client/for-<candidate>/`:** o `values.yaml` com `role: client` + `target` (derivados do contexto) e o `release.yaml` com o digest produtivo do client (lido do `gitops-production`). Para a `candidate/`, escreve `role: candidate` + a lista de clients (para o VirtualService) e o `release.yaml` com o digest da candidata. A config comum é herdada da raiz — o orquestrador não a duplica.