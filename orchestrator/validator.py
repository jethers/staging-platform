"""
validator.py — valida a existência das pastas e arquivos release.yaml no gitops.
"""

import os
import yaml


def validate_candidate(gitops_staging_path: str, service: str) -> None:
    """
    Verifica que a pasta candidate do serviço existe no gitops-staging.
    O release.yaml pode não existir — será criado pelo writer.
    """
    candidate_dir = os.path.join(gitops_staging_path, service, "candidate")
    if not os.path.isdir(candidate_dir):
        raise FileNotFoundError(
            f"[validator] Pasta candidate não encontrada: {candidate_dir}\n"
            f"  → Serviço '{service}' não está onboardado no gitops-staging."
        )


def validate_dependency(
    gitops_staging_path: str,
    gitops_production_path: str,
    service: str,
    dep: str,
) -> str:
    """
    Valida a dependência 'dep' para o serviço candidato 'service':
    - Pasta gitops-staging/<dep>/dependency/for-<service>/ deve existir
    - gitops-production/<dep>/release.yaml deve existir e ter digest preenchido

    Retorna o digest produtivo da dependência.
    """
    # Verifica pasta de dependency no gitops-staging
    dep_dir = os.path.join(gitops_staging_path, dep, "dependency", f"for-{service}")
    if not os.path.isdir(dep_dir):
        raise FileNotFoundError(
            f"[validator] Pasta de dependency não encontrada: {dep_dir}\n"
            f"  → Dependência '{dep}' não está onboardada para o serviço '{service}'.\n"
            f"  → Crie a pasta e os arquivos values.yaml e release.yaml."
        )

    # Verifica release.yaml de produção
    prod_release = os.path.join(gitops_production_path, dep, "release.yaml")
    if not os.path.isfile(prod_release):
        raise FileNotFoundError(
            f"[validator] release.yaml de produção não encontrado: {prod_release}\n"
            f"  → Dependência '{dep}' não tem gitops de produção configurado."
        )

    with open(prod_release) as f:
        data = yaml.safe_load(f)

    digest = (data.get("image") or {}).get("digest", "")
    if not digest:
        raise ValueError(
            f"[validator] Digest de produção vazio para dependência '{dep}': {prod_release}\n"
            f"  → Registre o digest manualmente (onboarding) ou aguarde o próximo deploy em produção."
        )

    return digest


def validate_client(
    gitops_staging_path: str,
    gitops_production_path: str,
    service: str,
    client: str,
) -> str:
    """
    Valida o client 'client' para o serviço candidato 'service':
    - Pasta gitops-staging/<client>/client/for-<service>/ deve existir
    - gitops-production/<client>/release.yaml deve existir e ter digest preenchido

    Retorna o digest produtivo do client.
    """
    # Verifica pasta de client no gitops-staging
    client_dir = os.path.join(gitops_staging_path, client, "client", f"for-{service}")
    if not os.path.isdir(client_dir):
        raise FileNotFoundError(
            f"[validator] Pasta de client não encontrada: {client_dir}\n"
            f"  → Client '{client}' não está onboardado para o serviço '{service}'.\n"
            f"  → Crie a pasta e os arquivos values.yaml e release.yaml."
        )

    # Verifica release.yaml de produção
    prod_release = os.path.join(gitops_production_path, client, "release.yaml")
    if not os.path.isfile(prod_release):
        raise FileNotFoundError(
            f"[validator] release.yaml de produção não encontrado: {prod_release}\n"
            f"  → Client '{client}' não tem gitops de produção configurado."
        )

    with open(prod_release) as f:
        data = yaml.safe_load(f)

    digest = (data.get("image") or {}).get("digest", "")
    if not digest:
        raise ValueError(
            f"[validator] Digest de produção vazio para client '{client}': {prod_release}\n"
            f"  → Registre o digest manualmente (onboarding) ou aguarde o próximo deploy em produção."
        )

    return digest
