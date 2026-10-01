#!/usr/bin/env python3
"""
orchestrator.py — orquestrador de homologação integrada.

Uso:
  python orchestrator.py --service <service> --digest <sha256:...> [--namespace <ns>]

Variáveis de ambiente (alternativa aos argumentos):
  SERVICE   nome do serviço
  DIGEST    digest SHA-256 da imagem candidata
  NAMESPACE namespace Kubernetes (default: default)

Caminhos resolvidos relativamente à raiz do repositório (dois níveis acima deste arquivo).
"""

import argparse
import os
import sys

import yaml

from manifest import load_dependencies, load_clients
from validator import validate_candidate, validate_dependency, validate_client
from writer import (
    write_candidate_release,
    write_dependency_release,
    write_client_release,
    write_candidate_values,
)

# Raiz do repositório (dois níveis acima de orchestrator/)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GITOPS_STAGING = os.path.join(REPO_ROOT, "gitops-staging")
GITOPS_PRODUCTION = os.path.join(REPO_ROOT, "gitops-production")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Orquestrador de homologação integrada"
    )
    parser.add_argument(
        "--service",
        default=os.environ.get("SERVICE"),
        help="Nome do serviço a ser homologado",
    )
    parser.add_argument(
        "--digest",
        default=os.environ.get("DIGEST"),
        help="Digest SHA-256 da imagem candidata (ex.: sha256:abc123...)",
    )
    parser.add_argument(
        "--namespace",
        default=os.environ.get("NAMESPACE", "default"),
        help="Namespace Kubernetes (default: default)",
    )
    return parser.parse_args()


def validate_inputs(service: str, digest: str) -> None:
    if not service:
        raise ValueError("--service é obrigatório")
    if not digest:
        raise ValueError("--digest é obrigatório")
    if not digest.startswith("sha256:"):
        raise ValueError(f"Digest inválido: '{digest}'. Deve começar com 'sha256:'")


def run(service: str, digest: str, namespace: str) -> None:
    print(f"\n{'='*60}")
    print(f"Orquestrador de Homologação")
    print(f"  serviço   : {service}")
    print(f"  digest    : {digest}")
    print(f"  namespace : {namespace}")
    print(f"{'='*60}\n")

    # 1. Lê manifestos de dependências e clients
    print("[1/4] Lendo manifestos de homologação...")
    dependencies = load_dependencies(GITOPS_STAGING, service)
    clients = load_clients(GITOPS_STAGING, service)
    print(f"  dependências : {dependencies or '(nenhuma)'}")
    print(f"  clients      : {clients or '(nenhum)'}")

    # 2. Valida candidata
    print("\n[2/4] Validando estrutura do gitops-staging...")
    validate_candidate(GITOPS_STAGING, service)
    print(f"  ✓ pasta candidate/{service} encontrada")

    # Valida dependências e coleta digests produtivos
    dep_digests: dict[str, str] = {}
    for dep in dependencies:
        dep_digests[dep] = validate_dependency(
            GITOPS_STAGING, GITOPS_PRODUCTION, service, dep
        )
        print(f"  ✓ dependência '{dep}' validada — digest: {dep_digests[dep][:20]}...")

    # Valida clients e coleta digests produtivos
    client_digests: dict[str, str] = {}
    for client in clients:
        client_digests[client] = validate_client(
            GITOPS_STAGING, GITOPS_PRODUCTION, service, client
        )
        print(f"  ✓ client '{client}' validado — digest: {client_digests[client][:20]}...")

    # 3. Escreve release.yaml da candidata
    print("\n[3/4] Atualizando gitops-staging...")
    write_candidate_release(GITOPS_STAGING, service, digest)

    # Escreve release.yaml das dependências
    for dep, dep_digest in dep_digests.items():
        write_dependency_release(GITOPS_STAGING, service, dep, dep_digest)

    # Escreve release.yaml dos clients
    for client, client_digest in client_digests.items():
        write_client_release(GITOPS_STAGING, service, client, client_digest)

    # 4. Atualiza candidate/values.yaml com VirtualService
    print("\n[4/4] Atualizando candidate/values.yaml com VirtualService...")
    write_candidate_values(GITOPS_STAGING, service, namespace, clients)

    print(f"\n{'='*60}")
    print("✓ gitops-staging atualizado com sucesso.")
    print("  O Argo CD irá detectar o commit e provisionar o ambiente.")
    print(f"{'='*60}\n")


def main() -> None:
    args = parse_args()

    try:
        validate_inputs(args.service, args.digest)
        run(args.service, args.digest, args.namespace)
    except (FileNotFoundError, ValueError) as e:
        print(f"\n✗ ERRO: {e}\n", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
