"""
manifest.py — lê os arquivos dependencies.yaml, clients.yaml e values.yaml do gitops-staging.
"""

import os
import yaml


def load_namespace(gitops_staging_path: str, service: str) -> str:
    """
    Lê gitops-staging/<service>/values.yaml e retorna o namespace do serviço.
    """
    path = os.path.join(gitops_staging_path, service, "values.yaml")
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"[manifest] values.yaml não encontrado: {path}\n"
            f"  → Serviço '{service}' não está onboardado no gitops-staging."
        )

    with open(path) as f:
        data = yaml.safe_load(f)

    namespace = (data or {}).get("namespace", "").strip()
    if not namespace:
        raise ValueError(
            f"[manifest] Campo 'namespace' não definido em: {path}\n"
            f"  → Adicione 'namespace: <seu-namespace>' ao values.yaml base do serviço."
        )

    return namespace


def load_dependencies(gitops_staging_path: str, service: str) -> list[str]:
    """
    Lê gitops-staging/<service>/dependencies.yaml e retorna a lista de dependências.
    Retorna lista vazia se o campo 'dependencies' não estiver definido.
    """
    path = os.path.join(gitops_staging_path, service, "dependencies.yaml")
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"[manifest] dependencies.yaml não encontrado: {path}\n"
            f"  → Serviço '{service}' não está onboardado no gitops-staging."
        )

    with open(path) as f:
        data = yaml.safe_load(f)

    return data.get("dependencies") or []


def load_clients(gitops_staging_path: str, service: str) -> list[str]:
    """
    Lê gitops-staging/<service>/clients.yaml e retorna a lista de regression clients.
    Retorna lista vazia se o campo 'regressionClients' não estiver definido.
    """
    path = os.path.join(gitops_staging_path, service, "clients.yaml")
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"[manifest] clients.yaml não encontrado: {path}\n"
            f"  → Serviço '{service}' não está onboardado no gitops-staging."
        )

    with open(path) as f:
        data = yaml.safe_load(f)

    return data.get("regressionClients") or []
