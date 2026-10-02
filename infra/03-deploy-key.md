# 03 — Deploy key SSH (read-only) para o Argo CD ler o repo privado

O repositório `jethers/staging-platform` é privado. O Argo CD autentica via SSH
usando uma **deploy key read-only** cadastrada só neste repo. A chave privada entra
no cluster como Secret e **nunca** é commitada.

## 1. Gerar o par de chaves (no WSL)

```bash
ssh-keygen -t ed25519 -C "argocd-staging-platform" -f ~/.ssh/argocd_staging_platform -N ""
```

Gera dois arquivos:
- `~/.ssh/argocd_staging_platform`      (privada — vai para o cluster)
- `~/.ssh/argocd_staging_platform.pub`  (pública — vai para o GitHub)

## 2. Cadastrar a chave pública como Deploy Key no GitHub

```bash
# imprime a chave pública para copiar
cat ~/.ssh/argocd_staging_platform.pub
```

No GitHub: repo **Settings → Deploy keys → Add deploy key**
- Title: `argocd`
- Key: cole o conteúdo acima
- **NÃO** marque "Allow write access" (queremos read-only)

Ou via `gh`:
```bash
gh repo deploy-key add ~/.ssh/argocd_staging_platform.pub \
  --repo jethers/staging-platform --title argocd
```

## 3. Criar o Secret de repositório no Argo (com a chave PRIVADA)

> Fazer **após** instalar o Argo (passo 04), pois usa o namespace `argocd`.
> A chave privada é lida do arquivo local — não vai para o git.

```bash
kubectl create secret generic repo-staging-platform \
  --namespace=argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:jethers/staging-platform.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd_staging_platform

kubectl label secret repo-staging-platform \
  --namespace=argocd \
  argocd.argoproj.io/secret-type=repository
```

O Argo passa a reconhecer o repo `git@github.com:jethers/staging-platform.git`
e consegue cloná-lo usando a chave read-only.

## Observação de produção

Para produto, a chave não deve ser aplicada "na mão" com `kubectl`. Use um gestor
de segredos (Sealed Secrets, SOPS, ou o Secret Manager do GCP com External Secrets).
Para a PoC, o `kubectl create secret` acima é suficiente e mantém a chave fora do git.
