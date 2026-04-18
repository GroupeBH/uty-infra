# Declencher le deploiement infra depuis le backend

Ce depot infra expose le workflow GitHub Actions `.github/workflows/deploy-infra.yml`.
Il accepte:

- un lancement manuel avec `workflow_dispatch`
- un declenchement distant avec `repository_dispatch` et l'evenement `backend-image-published`

Le flux attendu est:

1. push sur `master` dans le repo backend NestJS
2. appel `repository_dispatch` vers `GroupeBH/uty-infra` avec un tag Docker Hub deja publie
3. execution de `deploy.sh` dans ce repo infra
4. `terraform apply`, generation de l'inventaire, puis `ansible-playbook`

Le workflow `master` du repo `uty-api` ne doit donc pas obligatoirement rebuild l'image. Il peut simplement deployer un tag deja disponible dans Docker Hub, par exemple `latest`, `prod`, ou un tag immuable cree plus tot par le workflow des autres branches.

## Secrets et variables du repo infra

Configurer dans `GroupeBH/uty-infra`:

- `AWS_ACCESS_KEY_ID`: cle AWS utilisee par Terraform
- `AWS_SECRET_ACCESS_KEY`: secret AWS utilise par Terraform
- `AWS_SESSION_TOKEN`: optionnel, si les credentials AWS sont temporaires
- `EC2_SSH_PRIVATE_KEY`: cle privee SSH correspondant a `key_name`
- `TERRAFORM_TFVARS`: optionnel mais recommande, contenu complet de `terraform/terraform.tfvars`
- `APP_ENV_PRODUCTION`: optionnel, contenu du `.env.production` a copier sur les instances
- `DOCKERHUB_USERNAME`: optionnel, si l'image Docker Hub est privee
- `DOCKERHUB_TOKEN`: optionnel, si l'image Docker Hub est privee

Les droits AWS doivent couvrir Terraform pour cette infra, plus `ssm:SendCommand` et `ssm:GetCommandInvocation` pour la preconfiguration UFW avant SSH.

Variables de repository utiles:

- `AWS_REGION`: region AWS, par defaut `eu-central-1`
- `KEY_NAME`: override de `key_name`
- `ADMIN_CIDR`: override de `admin_cidr`
- `APP_IMAGE_REPOSITORY`: Docker Hub repository, par exemple `dockerhub-user/uty-api`
- `APP_IMAGE_TAG`: tag par defaut, par exemple `latest`
- `DOMAIN`: override de `domain_name`
- `CADDY_EMAIL`: override de `caddy_email`
- `INSTANCE_NAME`: override de `instance_name`
- `INSTANCE_TYPE`: override de `instance_type`
- `APP_HEALTHCHECK_PATH`: override de `app_healthcheck_path`

Le workflow detecte l'IP publique du runner GitHub Actions et la passe a Terraform via `additional_admin_cidrs`. Le runner peut donc se connecter en SSH pour Ansible sans remplacer `admin_cidr`. Pour les instances deja configurees avec UFW, `deploy.sh` tente d'abord d'ajouter ces CIDR SSH via AWS SSM, avant le test de connexion SSH.

## Secret du repo backend

Configurer dans le repo backend:

- `INFRA_REPO_DISPATCH_TOKEN`: token GitHub autorise a creer un `repository_dispatch` dans `GroupeBH/uty-infra`

Pour un fine-grained personal access token, donner au token l'acces au repo `GroupeBH/uty-infra` avec la permission `Contents: Read and write`. Pour un token classique, le scope `repo` suffit pour un repo prive.

## Workflow a ajouter dans `uty-api`

Si l'image est deja creee avant le merge vers `master`, ajouter un workflow dedie au deploiement dans le repo `uty-api`, par exemple `.github/workflows/deploy-infra.yml`:

```yaml
name: Deploy infra

on:
  push:
    branches:
      - master

permissions:
  contents: read

jobs:
  trigger-infra:
    name: Trigger uty infra deployment
    runs-on: ubuntu-latest

    steps:
      - name: Trigger infra deployment
        env:
          GH_TOKEN: ${{ secrets.INFRA_REPO_DISPATCH_TOKEN }}
          APP_IMAGE_REPOSITORY: ${{ vars.APP_IMAGE_REPOSITORY }}
          APP_IMAGE_TAG: ${{ vars.APP_IMAGE_TAG || 'latest' }}
        shell: bash
        run: |
          set -euo pipefail
          payload="$(
            printf '{"event_type":"backend-image-published","client_payload":{"image_repository":"%s","image_tag":"%s","backend_sha":"%s"}}' \
              "$APP_IMAGE_REPOSITORY" \
              "$APP_IMAGE_TAG" \
              "$GITHUB_SHA"
          )"

          curl --fail-with-body \
            --request POST \
            --header "Accept: application/vnd.github+json" \
            --header "Authorization: Bearer $GH_TOKEN" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/GroupeBH/uty-infra/dispatches \
            --data "$payload"
```

Si le workflow des autres branches publie un tag immuable, il faut que `APP_IMAGE_TAG` pointe vers ce tag deja existant. Attention: `github.sha` sur `master` n'est deployable que si une image avec ce SHA exact a deja ete poussee. Avec un merge commit ou un squash merge, ce SHA peut etre nouveau et ne pas exister dans Docker Hub.
