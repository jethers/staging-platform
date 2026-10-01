"""
validator.py — valida o onboarding dos serviços e os pré-requisitos de digest
no gitops, conforme o modelo MVP (dependências compartilhadas, sem dedicada).
"""

import os
import yaml


def _read_digest(path: str) -> str:
    """Lê o campo image.digest de um release.yaml. Retorna '' se vazio/ausente."""
    if not os.path.isfile(path):
        return ""
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    return (data.get("image") or {}).get("digest", "") or ""


def validate_onboarding(gitops_staging_path: str, service: str) -> None:
    """
    Verifica que um serviço está onboardado no gitops-staging:
    - <service>/values.yaml (base) deve existir
    - <service>/staging/ deve existir
    O orquestrador não cria essa estrutura (decisões 18 e 20).
    """
    base_values = os.path.join(gitops_staging_path, service, "values.yaml")
    staging_dir = os.path.join(gitops_staging_path, service, "staging")

    if not os.path.isfile(base_values):
        raise FileNotFoundError(
            f"[validator] Serviço '{service}' não onboardado: values.yaml base ausente ({base_values}).\n"
            f"  → Crie <service>/values.yaml (name, namespace, image, service.port)."
        )
    if not os.path.isdir(staging_dir):
        raise FileNotFoundError(
            f"[validator] Serviço '{service}' não onboardado: pasta staging/ ausente ({staging_dir}).\n"
            f"  → Crie <service>/staging/ com values.yaml (role: staging) e release.yaml."
        )


def validate_dependency_shared(gitops_staging_path: str, dep: str) -> None:
    """
    Valida uma dependência compartilhada (modelo MVP):
    - O serviço da dependência deve estar onboardado
    - O staging/release.yaml da dependência deve ter digest preenchido (runtime ativo),
      pois a candidata vai consumir esse runtime compartilhado.
    """
    validate_onboarding(gitops_staging_path, dep)

    staging_release = os.path.join(
        gitops_staging_path, dep, "staging", "release.yaml"
    )
    digest = _read_digest(staging_release)
    if not digest:
        raise ValueError(
            f"[validator] Dependência '{dep}' sem runtime compartilhado ativo: "
            f"digest vazio em {staging_release}.\n"
            f"  → Preencha o digest do runtime compartilhado do '{dep}' em staging/release.yaml "
            f"(a candidata consome a versão compartilhada da dependência)."
        )


def validate_client_prod_digest(gitops_production_path: str, client: str) -> str:
    """
    Valida que o client tem digest produtivo registrado e o retorna.
    O client de regressão roda na versão produtiva.
    """
    prod_release = os.path.join(gitops_production_path, client, "release.yaml")
    if not os.path.isfile(prod_release):
        raise FileNotFoundError(
            f"[validator] release.yaml de produção não encontrado para client '{client}': {prod_release}\n"
            f"  → Client '{client}' não tem gitops de produção configurado."
        )
    digest = _read_digest(prod_release)
    if not digest:
        raise ValueError(
            f"[validator] Digest de produção vazio para client '{client}': {prod_release}\n"
            f"  → Registre o digest manualmente (onboarding) ou aguarde o próximo deploy em produção."
        )
    return digest
