# uty AWS infra

Cette base deploie une API NestJS packagee sur Docker Hub derriere Caddy, avec une architecture AWS simple, low-cost et plus robuste: deux noeuds EC2, une Elastic IP par noeud, un DNS externe a AWS, Terraform pour le provisioning et Ansible pour la configuration systeme et le deploiement applicatif. Chaque instance execute Caddy et l'application, et chaque Caddy peut router vers le backend local et celui du pair via le reseau prive.

## Ce que le depot provisionne

- 1 VPC avec `enable_dns_support` et `enable_dns_hostnames`
- 1 Internet Gateway
- 2 subnets publics, idealement dans 2 AZ differentes
- 1 route table publique avec route `0.0.0.0/0`
- 1 security group partage pour SSH, HTTP, HTTPS et le trafic applicatif inter-noeuds
- 2 instances EC2 Ubuntu 22.04 LTS Canonical
- 2 Elastic IPs, une par noeud
- 1 IAM role EC2 avec SSM et CloudWatch Agent policies
- 4 log groups CloudWatch au total, 2 par noeud (`app` et `caddy`)
- 2 alarmes CloudWatch par noeud
- 1 topic SNS optionnel si des emails d'alerte sont fournis
- des parametres SSM SecureString optionnels

## Topologie applicative

- Chaque instance execute une stack `Caddy -> app NestJS`.
- Caddy peut equilibrer vers l'app locale et l'app distante en utilisant les IPs privees EC2 et un health check HTTP sur `app_healthcheck_path`.
- En mode le plus robuste, le DNS externe peut publier les 2 Elastic IPs pour distribuer l'entree entre les deux noeuds.
- Si votre provider DNS ou votre strategie TLS ne permet pas ce mode, vous pouvez garder un seul `A` record public tout en profitant du failover backend inter-noeuds.
- Caddy termine HTTP ou HTTPS directement sur chaque instance.
- L'application NestJS n'est jamais clonee sur les serveurs: seul le conteneur Docker Hub est deploye.
- Les logs Docker sont envoyes dans CloudWatch Logs via le driver `awslogs`.

## Arborescence

```text
.github/
  workflows/
    deploy-infra.yml
terraform/
  main.tf
  variables.tf
  outputs.tf
  terraform.tfvars.example
  backend.hcl
  backend.hcl.example
ansible/
  playbook.yml
  inventory.ini
  files/
    docker-compose.yml.j2
    Caddyfile.j2
deploy.sh
docs/
  low-cost-failover.md
  manual-failover-runbook.md
  backend-deploy-trigger.md
```

## Prerequis operateur

- Terraform `>= 1.5`
- provider AWS `~> 5.0`
- Ansible installe sur la machine d'execution
- acces AWS deja configure (`AWS_PROFILE`, variables d'environnement AWS ou SSO)
- une key pair EC2 existante
- l'image Docker Hub de l'API NestJS deja publiee
- un provider DNS externe permettant soit de publier 2 `A` records, soit de modifier rapidement le `A` record actif

## Mise en route rapide

1. Preparer la configuration locale:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# terraform/backend.hcl already points to s3://uty-tfstate/uty/terraform.tfstate
# edit it only if you need a different key, region or a DynamoDB lock table
```

2. Adapter au minimum:

- `key_name`
- `admin_cidr`
- `additional_admin_cidrs` si un runner CI doit aussi se connecter en SSH
- `app_image_repository`
- `domain_name` si vous voulez HTTPS automatique avec Caddy
- `caddy_email` si vous voulez enregistrer un email ACME

3. Lancer le deploiement:

```bash
PRIVATE_KEY_PATH=~/.ssh/my-ec2-key.pem ./deploy.sh
# if .env.production exists at the repository root, deploy.sh loads it automatically
```

Exemple avec overrides CLI:

```bash
./deploy.sh \
  --private-key-path ~/.ssh/my-ec2-key.pem \
  --key-name my-ec2-keypair \
  --admin-cidr 198.51.100.10/32 \
  --app-image-repository dockerhub-user/uty-api \
  --app-image-tag latest \
  --domain api.example.com \
  --caddy-email ops@example.com
```

## Fonctionnement de `deploy.sh`

Le script:

1. charge automatiquement `terraform/terraform.tfvars` si present
2. charge automatiquement `terraform/backend.hcl` si present
3. accepte des overrides via variables d'environnement et flags CLI
4. exige `PRIVATE_KEY_PATH`
5. execute `terraform init`
6. execute `terraform apply`
7. lit les outputs Terraform utiles au deploiement
8. genere `ansible/inventory.ini` avec `primary` et `secondary` si active
9. injecte les IPs publiques et privees de chaque noeud dans l'inventaire Ansible
10. attend la disponibilite SSH sur chaque noeud
11. execute `ansible/playbook.yml`

## Deploiement automatique depuis le backend

Le workflow `.github/workflows/deploy-infra.yml` peut etre lance manuellement ou par `repository_dispatch` avec l'evenement `backend-image-published`. Le repo backend peut donc declencher ce repo infra juste apres avoir pousse l'image Docker Hub.

Le workflow ajoute automatiquement l'IP publique du runner GitHub Actions dans `additional_admin_cidrs`, puis execute `deploy.sh`. Cela permet a Terraform d'ouvrir SSH pour le runner pendant le deploiement Ansible, tout en conservant `admin_cidr` pour l'acces operateur. Avant la connexion SSH, `deploy.sh` tente aussi une preconfiguration UFW via AWS SSM pour les instances deja deployees.

Voir [Backend deploy trigger](docs/backend-deploy-trigger.md).

## Fournir un `.env` local

Si l'application a besoin de secrets ou de variables d'environnement, vous pouvez soit laisser `deploy.sh` auto-detecter `./.env.production`, soit fournir explicitement un fichier local via `APP_ENV_FILE` ou `--app-env-file`.

Le fichier detecte est uniquement utilise comme fichier d'environnement applicatif pour le conteneur NestJS. Il est copie vers `/opt/nestjs-caddy/.env` sur chaque instance avec des permissions `0600`, mais il n'est pas charge localement pour Terraform ni pour la configuration du poste de controle Ansible.

## Outputs Terraform utiles

Quelques outputs importants apres `terraform apply`:

- `app_url`
- `health_url`
- `elastic_ip`
- `secondary_elastic_ip`
- `private_ip`
- `secondary_private_ip`
- `external_dns_failover_targets`
- `external_dns_active_active_targets`
- `ssh_command`
- `secondary_ssh_command`
- `cloudwatch_log_group_app`
- `cloudwatch_log_group_caddy`
- `ops_alerts_topic_arn`
- `deploy_admin_cidrs`
- `deploy_admin_cidrs_csv`
- `deploy_instance_ids_csv`

Exemple:

```bash
terraform -chdir=terraform output app_url
terraform -chdir=terraform output external_dns_failover_targets
terraform -chdir=terraform output external_dns_active_active_targets
terraform -chdir=terraform output ssh_commands
```

## Verifier les logs CloudWatch

Les logs attendus sont:

- `/<instance_name>/app`
- `/<instance_name>/caddy`
- `/<instance_name>-secondary/app`
- `/<instance_name>-secondary/caddy`

Exemples avec AWS CLI:

```bash
aws logs tail /uty-api/app --follow --region us-east-1
aws logs tail /uty-api/caddy --follow --region us-east-1
aws logs tail /uty-api-secondary/app --follow --region us-east-1
```

## Debug rapide

```bash
terraform -chdir=terraform output
ssh -i ~/.ssh/my-ec2-key.pem ubuntu@<primary_eip>
ssh -i ~/.ssh/my-ec2-key.pem ubuntu@<secondary_eip>
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml --syntax-check
```

Sur une instance:

```bash
cd /opt/nestjs-caddy
docker compose ps
docker compose logs app --tail=100
docker compose logs caddy --tail=100
docker inspect nestjs-app
sudo ufw status verbose
```

## Securite et points d'attention

- SSH n'est autorise que depuis `admin_cidr` et `additional_admin_cidrs` au niveau AWS et UFW.
- HTTP et HTTPS restent exposes a Internet, car Caddy termine le trafic en frontal.
- Le port applicatif `3000` n'est plus limite au loopback: il est ouvert uniquement entre les instances du cluster au niveau Security Group et UFW pour permettre le proxy inter-noeuds.
- `PRIVATE_KEY_PATH` doit rester sur le poste operateur, jamais sur le depot.
- Les secrets applicatifs peuvent vivre dans un `.env` local et/ou dans SSM Parameter Store.
- Le mode DNS a 2 `A` records ameliore la disponibilite mais reste un equilibrage best effort cote client ou resolver, pas l'equivalent d'un vrai ALB.
- Le modele reste simple et low-cost, mais ne remplace pas un vrai HA manage avec ALB, Auto Scaling, health checks distribues et certificats centralises.

## Documentation complementaire

- [Low-cost failover](docs/low-cost-failover.md)
- [Manual failover runbook](docs/manual-failover-runbook.md)
- [Backend deploy trigger](docs/backend-deploy-trigger.md)
