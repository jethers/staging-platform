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

## 3. Dependências na versão produtiva vigente

**Decisão:** a candidata é sempre testada contra as versões produtivas vigentes de suas dependências, não contra outras candidatas.

**Motivação:** simular o ambiente que a candidata encontrará em produção. Testar contra outras candidatas introduziria variáveis desconhecidas e tornaria os resultados menos confiáveis.

**Dependências transitivas:** por padrão resolvem para o serviço compartilhado (`staging`). Isolamento total do caminho transitivo pode ser declarado explicitamente via `dependencies.yaml`.

---

## 4. gitops-production como fonte de verdade dos digests produtivos

**Decisão:** o orquestrador busca os digests das dependências no repositório `gitops-production`, não diretamente no cluster de produção.

**Motivação:** desacopla a plataforma de homologação do mecanismo de deploy de produção. O `gitops-production` funciona como um registro — qualquer CD de produção pode atualizá-lo ao finalizar um deploy.

**Restrição:** dependência ou client sem digest registrado em `gitops-production` resulta em erro explícito. O ciclo de homologação não prossegue.

---

## 5. Bootstrap manual para serviços existentes

**Decisão:** serviços que já estavam em produção antes da adoção da plataforma podem ter seus digests registrados manualmente no `gitops-production`.

**Motivação:** evitar que a adoção da plataforma force um re-deploy desnecessário de todos os serviços existentes. O onboarding deve ser gradual e não disruptivo.

**Processo:** após o registro manual, o serviço passa a seguir o fluxo normal — cada novo deploy em produção atualiza o `gitops-production` automaticamente.

---

## 6. `release.yaml` separado dos `values.yaml`

**Decisão:** o digest da imagem fica em um arquivo `release.yaml` separado dos demais valores de configuração.

**Motivação:** o digest é o único campo alterado pelo orquestrador a cada ciclo. Isolá-lo facilita diffs, revisões e automação — a automação modifica apenas `release.yaml`, nunca `values.yaml`.

---

## 7. Helm Chart genérico com hierarquia de values

**Decisão:** um único chart genérico serve para todos os serviços. A especialização é feita via arquivos de values em camadas: `values.yaml` (base) → `<ambiente>/values.yaml` (overrides) → `<ambiente>/release.yaml` (digest).

**Motivação:** reduz duplicação, facilita manutenção e garante consistência entre serviços. Novos serviços precisam apenas de seus arquivos de values — nenhum código de chart precisa ser escrito.
