#!/usr/bin/env python3
"""
orchestrator.py — orquestrador de homologação integrada.

Uso:
  python orchestrator.py --service <service> --digest <sha256:...>

Variáveis de ambiente obrigatórias (configuradas no Helm chart do orquestrador):
  SERVICE              nome do serviço (pode ser passado via --service)
  DIGEST               digest SHA-256 da imagem candidata (pode ser passado via --digest)
  GITOPS_STAGING_PATH  path local do repositório gitops-staging
  GITOPS_PROD_PATH     path local do repositório gitops-production
  NAMESPACE            namespace Kubernetes dos serviços
"""

import argparse
import os
import sys

from manifest import load_dependencies, load_clients, load_namespace
from validator import validate_candidate, validate_dependency, validate_client
from writer import (
    write_candidate_release,
    write_dependency_release,
    write_client_release,
    write_candidate_values,
)


def get_env(name: str, required: bool = True) -> str:
    """Lê variável de ambiente, falhando explicitamente se obrigatória e ausente."""
    value = os.environ.get(name, "").strip()
    if required and not value:
        raise ValueError(
            f"Variável de ambiente obrigatória não definida: {name}\n"
            f"  → Configure-a no Helm chart do orquestrador ou no arquivo .env local."
        )
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Orquestrador de homologação integrada"
    )
    parser.add_argument(
        "--service",
        default=os.environ.get("SERVICE"),
        help="Nome do serviço a ser homologado (ou via env SERVICE)",
    )
    parser.add_argument(
        "--digest",
        default=os.environ.get("DIGEST"),
        help="Digest SHA-256 da imagem candidata (ou via env DIGEST)",
    )
    return parser.parse_args()


def validate_inputs(service: str, digest: str) -> None:
    if not service:
        raise ValueError("--service é obrigatório (ou env SERVICE)")
    if not digest:
        raise ValueError("--digest é obrigatório (ou env DIGEST)")
    if not digest.startswith("sha256:"):
        raise ValueError(f"Digest inválido: '{digest}'. Deve começar com 'sha256:'")


def run(service: str, digest: str) -> None:
    # Configurações vindas do Helm chart do orquestrador via variáveis de ambiente
    gitops_staging = get_env("GITOPS_STAGING_PATH")
    gitops_production = get_env("GITOPS_PROD_PATH")

    # Namespace lido do values.yaml base do serviço no gitops-staging
    namespace = load_namespace(gitops_staging, service)

    print(f"\n{'='*60}")
    print(f"Orquestrador de Homologação")
    print(f"  serviço            : {service}")
    print(f"  digest             : {digest}")
    print(f"  namespace          : {namespace}")
    print(f"  gitops-staging     : {gitops_staging}")
    print(f"  gitops-production  : {gitops_production}")
    print(f"{'='*60}\n")

    # 1. Lê manifestos de dependências e clients
    print("[1/4] Lendo manifestos de homologação...")
    dependencies = load_dependencies(gitops_staging, service)
    clients = load_clients(gitops_staging, service)
    print(f"  dependências : {dependencies or '(nenhuma)'}")
    print(f"  clients      : {clients or '(nenhum)'}")

    # 2. Valida candidata
    print("\n[2/4] Validando estrutura do gitops-staging...")
    validate_candidate(gitops_staging, service)
    print(f"  ✓ pasta candidate/{service} encontrada")

    # Valida dependências e coleta digests produtivos
    dep_digests: dict[str, str] = {}
    for dep in dependencies:
        dep_digests[dep] = validate_dependency(
            gitops_staging, gitops_production, service, dep
        )
        print(f"  ✓ dependência '{dep}' validada — digest: {dep_digests[dep][:20]}...")

    # Valida clients e coleta digests produtivos
    client_digests: dict[str, str] = {}
    for client in clients:
        client_digests[client] = validate_client(
            gitops_staging, gitops_production, service, client
        )
        print(f"  ✓ client '{client}' validado — digest: {client_digests[client][:20]}...")

    # 3. Escreve release.yaml da candidata
    print("\n[3/4] Atualizando gitops-staging...")
    write_candidate_release(gitops_staging, service, digest)

    # Escreve release.yaml das dependências
    for dep, dep_digest in dep_digests.items():
        write_dependency_release(gitops_staging, service, dep, dep_digest)

    # Escreve release.yaml dos clients
    for client, client_digest in client_digests.items():
        write_client_release(gitops_staging, service, client, client_digest)

    # 4. Atualiza candidate/values.yaml com VirtualService
    print("\n[4/4] Atualizando candidate/values.yaml com VirtualService...")
    write_candidate_values(gitops_staging, service, namespace, clients)

    print(f"\n{'='*60}")
    print("✓ gitops-staging atualizado com sucesso.")
    print("  O Argo CD irá detectar o commit e provisionar o ambiente.")
    print(f"{'='*60}\n")


def main() -> None:
    args = parse_args()

    try:
        validate_inputs(args.service, args.digest)
        run(args.service, args.digest)
    except (FileNotFoundError, ValueError) as e:
        print(f"\n✗ ERRO: {e}\n", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
