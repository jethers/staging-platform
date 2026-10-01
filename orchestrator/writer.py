"""
writer.py — cria as pastas efêmeras (candidate e clients) no gitops-staging,
conforme o modelo MVP.
"""

import os
import yaml


def _dump(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)


def write_candidate(
    gitops_staging_path: str,
    service: str,
    digest: str,
    clients: list[str],
) -> None:
    """
    Cria/atualiza a pasta candidate/ do serviço:
    - values.yaml: role: candidate + lista de clients (labels app dos clients de regressão),
      usada pelo chart para gerar o VirtualService (rotas client → candidata).
    - release.yaml: digest da candidata.

    Idempotente: se a pasta já existe (rebuild), sobrescreve os arquivos; o Git só
    gera commit se o conteúdo mudar.
    """
    base = os.path.join(gitops_staging_path, service, "candidate")

    # Lista de labels 'app' dos clients de regressão: <client>-<service>-client
    client_labels = [f"{client}-{service}-client" for client in clients]

    values = {"role": "candidate"}
    if client_labels:
        values["clients"] = client_labels

    _dump(os.path.join(base, "values.yaml"), values)
    _dump(os.path.join(base, "release.yaml"), {"image": {"digest": digest}})
    print(f"[writer] candidate atualizado: {base}")


def write_client(
    gitops_staging_path: str,
    service: str,
    client: str,
    digest: str,
) -> None:
    """
    Cria/atualiza a pasta client/for-<service>/ do serviço client:
    - values.yaml: role: client, target: <service>, istioInject: true
      (o client origina o desvio para a candidata — precisa de sidecar).
    - release.yaml: digest produtivo do client.
    """
    base = os.path.join(gitops_staging_path, client, "client", f"for-{service}")

    values = {
        "role": "client",
        "target": service,
        "istioInject": True,
    }
    _dump(os.path.join(base, "values.yaml"), values)
    _dump(os.path.join(base, "release.yaml"), {"image": {"digest": digest}})
    print(f"[writer] client atualizado: {base}")
