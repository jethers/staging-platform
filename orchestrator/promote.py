#!/usr/bin/env python3
"""
promote.py — processo pós-deploy: atualização e limpeza da homologação.

Acionado após uma candidata ser promovida e deployada em produção com sucesso.
Executa dois processos sobre o gitops-staging:

1. ATUALIZAÇÃO — propaga o novo digest produtivo do serviço para todos os seus
   usos produtivos em homologação (staging compartilhado e pastas client/for-* em
   outras candidatas), atualizando apenas os release.yaml que já têm runtime ativo.

2. LIMPEZA — remove os efêmeros da homologação encerrada: a pasta candidate/ do
   serviço e todas as pastas */client/for-<service>/ (clients que testavam este serviço).

Uso:
  python promote.py --service <service> --digest <sha256:...>

Variáveis de ambiente:
  SERVICE              nome do serviço promovido (ou via --service)
  DIGEST               novo digest produtivo (ou via --digest)
  GITOPS_STAGING_PATH  path do repositório gitops-staging (obrigatória)
"""

import argparse
import glob
import os
import shutil
import sys

import yaml


def get_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(
            f"Variável de ambiente obrigatória não definida: {name}"
        )
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Pós-deploy: atualização e limpeza da homologação"
    )
    parser.add_argument("--service", default=os.environ.get("SERVICE"))
    parser.add_argument("--digest", default=os.environ.get("DIGEST"))
    return parser.parse_args()


def validate_inputs(service: str, digest: str) -> None:
    if not service:
        raise ValueError("--service é obrigatório (ou env SERVICE)")
    if not digest:
        raise ValueError("--digest é obrigatório (ou env DIGEST)")
    if not digest.startswith("sha256:"):
        raise ValueError(f"Digest inválido: '{digest}'. Deve começar com 'sha256:'")


def _read_digest(path: str) -> str:
    if not os.path.isfile(path):
        return ""
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    return (data.get("image") or {}).get("digest", "") or ""


def _write_digest(path: str, digest: str) -> None:
    with open(path, "w") as f:
        yaml.dump({"image": {"digest": digest}}, f, default_flow_style=False, sort_keys=False)


def update_production_uses(gitops_staging: str, service: str, new_digest: str) -> None:
    """
    Atualiza o digest em todos os usos produtivos do serviço no staging:
    todos os release.yaml sob gitops-staging/<service>/, exceto candidate/
    (que será destruída), que já tenham digest preenchido (runtime ativo).
    """
    print("[1/2] Atualizando usos produtivos do serviço em homologação...")
    service_dir = os.path.join(gitops_staging, service)
    pattern = os.path.join(service_dir, "**", "release.yaml")

    updated = 0
    for release_path in glob.glob(pattern, recursive=True):
        # pula a candidata (será removida na limpeza)
        rel = os.path.relpath(release_path, service_dir)
        if rel.startswith("candidate" + os.sep):
            continue
        # só atualiza se já havia runtime ativo (digest preenchido)
        current = _read_digest(release_path)
        if current and current != new_digest:
            _write_digest(release_path, new_digest)
            print(f"  ✓ atualizado: {release_path}")
            updated += 1
    if updated == 0:
        print("  (nenhum uso produtivo com runtime ativo a atualizar)")


def cleanup_ephemeral(gitops_staging: str, service: str) -> None:
    """
    Remove os efêmeros da homologação encerrada:
    - a pasta candidate/ do serviço promovido
    - todas as pastas */client/for-<service>/ (clients que testavam este serviço)
    """
    print("\n[2/2] Removendo efêmeros da homologação encerrada...")

    # 1. candidata do serviço promovido
    candidate_dir = os.path.join(gitops_staging, service, "candidate")
    if os.path.isdir(candidate_dir):
        shutil.rmtree(candidate_dir)
        print(f"  ✓ removido: {candidate_dir}")

    # 2. clients que testavam este serviço: */client/for-<service>/
    pattern = os.path.join(gitops_staging, "*", "client", f"for-{service}")
    removed = 0
    for client_dir in glob.glob(pattern):
        if os.path.isdir(client_dir):
            shutil.rmtree(client_dir)
            print(f"  ✓ removido: {client_dir}")
            removed += 1
            # remove a pasta client/ se ficou vazia
            parent = os.path.dirname(client_dir)
            if os.path.isdir(parent) and not os.listdir(parent):
                os.rmdir(parent)

    if removed == 0 and not os.path.isdir(candidate_dir):
        print("  (nenhum efêmero a remover)")


def run(service: str, digest: str) -> None:
    gitops_staging = get_env("GITOPS_STAGING_PATH")

    print(f"\n{'='*60}")
    print("Pós-deploy: atualização e limpeza da homologação")
    print(f"  serviço promovido : {service}")
    print(f"  novo digest prod  : {digest}")
    print(f"  gitops-staging    : {gitops_staging}")
    print(f"{'='*60}\n")

    update_production_uses(gitops_staging, service, digest)
    cleanup_ephemeral(gitops_staging, service)

    print(f"\n{'='*60}")
    print("✓ Pós-deploy concluído.")
    print("  Commit + push para o Argo CD aplicar atualização e prune.")
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
