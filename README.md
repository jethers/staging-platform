# Staging Platform — PoC de Homologação Integrada

Plataforma de homologação integrada para microsserviços. Serviços candidatos são testados em ambiente isolado com as versões produtivas das dependências.

## Documentação

- [Arquitetura](docs/architecture.md) — visão geral da solução, componentes e fluxo
- [Decisões de design](docs/decisions.md) — registro das principais decisões arquiteturais
- [Onboarding](docs/onboarding.md) — como integrar um novo serviço na plataforma
- [Orquestrador](docs/orchestrator.md) — como o orquestrador funciona

---

---

## Serviços

| Serviço | Porta | Descrição |
|---------|-------|-----------|
| `ledger` | 8081 | Serviço de saldo. Expõe balanço de contas. |
| `wallet` | 8082 | Serviço de carteira. Consome o `ledger` e enriquece a resposta. |

---

## Subindo o ambiente

```bash
# Na raiz do projeto
docker compose up -d
```

Para acompanhar os logs em tempo real (filtrando healthchecks):

```bash
docker compose logs -f | grep -v "/health"
```

Para derrubar:

```bash
docker compose down
```

---

## Testando as APIs

### ledger

```bash
# Health
curl http://localhost:8081/health

# Saldo de uma conta
curl http://localhost:8081/balance/123
curl http://localhost:8081/balance/abc
```

Resposta esperada de `/balance/{account}`:
```json
{
  "account": "123",
  "balance": 1150.5,
  "currency": "BRL"
}
```

> O saldo é mockado e determinístico — a mesma conta sempre retorna o mesmo valor.

---

### wallet

```bash
# Health
curl http://localhost:8082/health

# Carteira de uma conta (chama o ledger internamente)
curl http://localhost:8082/wallet/123
curl http://localhost:8082/wallet/abc
```

Resposta esperada de `/wallet/{account}`:
```json
{
  "account": "123",
  "balance": 1150.5,
  "currency": "BRL",
  "wallet_status": "active"
}
```

---

## O que aparece nos logs

Uma requisição em `GET /wallet/123` gera 3 linhas de log:

```
# wallet recebeu a requisição
wallet-1  | request_id=abc method=GET path=/wallet/123 status=200 latency=16ms

# wallet chamou o ledger (upstream)
wallet-1  | upstream=ledger account=123 status=200 latency=16ms

# ledger recebeu a chamada vinda do wallet
ledger-1  | request_id=xyz method=GET path=/balance/123 status=200 latency=100µs
```

---

## Rodando sem Docker

Em dois terminais separados:

```bash
# Terminal 1 — ledger
cd services/ledger
PORT=8081 go run .

# Terminal 2 — wallet
cd services/wallet
PORT=8082 LEDGER_URL=http://localhost:8081 go run .
```

---

## Estrutura do projeto

```
staging-platform/
  services/
    ledger/               # Serviço de saldo (Go)
      homologation/
        dependencies.yaml # Dependências do ledger
        clients.yaml      # Clientes de regressão do ledger
    wallet/               # Serviço de carteira (Go)
      homologation/
        dependencies.yaml # Dependências do wallet (ledger)
        clients.yaml      # Clientes de regressão do wallet
  helm/
    service-chart/        # Helm Chart genérico para qualquer serviço
    values-ledger.yaml    # Values específicos do ledger
    values-wallet.yaml    # Values específicos do wallet
  docker-compose.yaml
```
