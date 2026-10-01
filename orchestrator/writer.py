"""
writer.py — escreve os release.yaml e atualiza o candidate/values.yaml no gitops-staging.
"""

import os
import yaml


def _write_release(path: str, digest: str) -> None:
    """Escreve ou sobrescreve um release.yaml com o digest fornecido."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        yaml.dump({"image": {"digest": digest}}, f, default_flow_style=False)
    print(f"[writer] release.yaml atualizado: {path}")


def write_candidate_release(
    gitops_staging_path: str, service: str, digest: str
) -> None:
    """Escreve o release.yaml da candidata."""
    path = os.path.join(gitops_staging_path, service, "candidate", "release.yaml")
    _write_release(path, digest)


def write_dependency_release(
    gitops_staging_path: str, service: str, dep: str, digest: str
) -> None:
    """Escreve o release.yaml da dependência dedicada."""
    path = os.path.join(
        gitops_staging_path, dep, "dependency", f"for-{service}", "release.yaml"
    )
    _write_release(path, digest)


def write_client_release(
    gitops_staging_path: str, service: str, client: str, digest: str
) -> None:
    """Escreve o release.yaml do client de regressão."""
    path = os.path.join(
        gitops_staging_path, client, "client", f"for-{service}", "release.yaml"
    )
    _write_release(path, digest)


def write_candidate_values(
    gitops_staging_path: str,
    service: str,
    namespace: str,
    clients: list[str],
) -> None:
    """
    Atualiza o candidate/values.yaml com a configuração do VirtualService,
    incluindo o host da candidata e a lista de clientRoutes.
    """
    path = os.path.join(gitops_staging_path, service, "candidate", "values.yaml")

    # Lê values existentes se houver
    existing = {}
    if os.path.isfile(path):
        with open(path) as f:
            existing = yaml.safe_load(f) or {}

    # Monta configuração do VirtualService
    shared_host = f"{service}.{namespace}.svc.cluster.local"
    candidate_host = f"{service}-candidate.{namespace}.svc.cluster.local"
    client_routes = [
        {"sourceApp": f"{client}-{service}-client"} for client in clients
    ]

    existing["virtualService"] = {
        "enabled": bool(clients),
        "host": shared_host,
        "candidateHost": candidate_host,
        "clientRoutes": client_routes,
    }

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        yaml.dump(existing, f, default_flow_style=False)

    print(f"[writer] candidate/values.yaml atualizado: {path}")
