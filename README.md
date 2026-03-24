# uty AWS infra

Cette base déploie une API NestJS packagée sur Docker Hub derrière Caddy, avec une architecture AWS simple, low-cost et opérable: un nœud primaire, un nœud secondaire de secours, des Elastic IPs fixes, un DNS externe à AWS, Terraform pour le provisioning et Ansible pour la configuration système et le déploiement applicatif.

## Ce que le dépôt provisionne

- 1 VPC avec `enable_dns_support` et `enable_dns_hostnames`
- 1 Internet Gateway
- 2 subnets publics, idéalement dans 2 AZ différentes
- 1 route table publique avec route `0.0.0.0/0`
- 1 security group partagé pour SSH, HTTP et HTTPS
- 2 instances EC2 Ubuntu 22.04 LTS Canonical
- 2 Elastic IPs, une par nœud
- 1 IAM role EC2 avec SSM et CloudWatch Agent policies
- 4 log groups CloudWatch au total, 2 par nœud (`app` et `caddy`)
- 2 alarmes CloudWatch par nœud
- 1 topic SNS optionnel si des emails d'alerte sont fournis
- des paramètres SSM SecureString optionnels

## Topologie applicative

- Le trafic normal doit pointer vers l'Elastic IP du nœud primaire.
- Le nœud secondaire reste prêt à servir mais ne reçoit pas le trafic tant que le DNS externe n'est pas modifié.
- Caddy termine HTTP ou HTTPS directement sur chaque instance.
- L'application NestJS n'est jamais clonée sur les serveurs: seul le conteneur Docker Hub est déployé.
- Les logs Docker sont envoyés dans CloudWatch Logs via le driver `awslogs`.

## Arborescence

```text
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
```

## Prérequis opérateur

- Terraform `>= 1.5`
- provider AWS `~> 5.0`
- Ansible installé sur la machine d'exécution
- accès AWS déjà configuré (`AWS_PROFILE`, variables d'environnement AWS ou SSO)
- une key pair EC2 existante
- l'image Docker Hub de l'API NestJS déjà publiée
- un provider DNS externe permettant de modifier le `A` record

## Mise en route rapide

1. Préparer la configuration locale:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# terraform/backend.hcl already points to s3://uty-tfstate/uty/terraform.tfstate
# edit it only if you need a different key, region or a DynamoDB lock table
```

2. Adapter au minimum:

- `key_name`
- `admin_cidr`
- `app_image_repository`
- `domain_name` si vous voulez HTTPS automatique avec Caddy
- `caddy_email` si vous voulez enregistrer un email ACME

3. Lancer le déploiement:

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

1. charge automatiquement `terraform/terraform.tfvars` si présent
2. charge automatiquement `terraform/backend.hcl` si présent
3. accepte des overrides via variables d'environnement et flags CLI
4. exige `PRIVATE_KEY_PATH`
5. exécute `terraform init`
6. exécute `terraform apply`
7. lit les outputs Terraform utiles au déploiement
8. génère `ansible/inventory.ini` avec `primary` et `secondary` si activé
9. attend la disponibilité SSH sur chaque nœud
10. exécute `ansible/playbook.yml`

Si vous fournissez une configuration backend S3, `deploy.sh` génère un fichier Terraform local temporaire de backend pour permettre l'usage d'un state distant sans imposer S3 comme mode par défaut.

## Fournir un `.env` local

Si l'application a besoin de secrets ou de variables d'environnement, vous pouvez soit laisser `deploy.sh` auto-détecter `./.env.production`, soit fournir explicitement un fichier local via `APP_ENV_FILE` ou `--app-env-file`.

Le fichier détecté est uniquement utilisé comme fichier d'environnement applicatif pour le conteneur NestJS. Il est copié vers `/opt/nestjs-caddy/.env` sur chaque instance avec des permissions `0600`, mais il n'est pas chargé localement pour Terraform ni pour la configuration du poste de contrôle Ansible.

Les credentials AWS nécessaires à Terraform doivent venir de votre shell, de `AWS_PROFILE` ou de votre configuration AWS locale, pas de `.env.production`.

Exemple avec auto-détection de `./.env.production`:

```bash
PRIVATE_KEY_PATH=~/.ssh/my-ec2-key.pem ./deploy.sh
```

Exemple avec un autre fichier:

```bash
APP_ENV_FILE=./env/prod.env PRIVATE_KEY_PATH=~/.ssh/my-ec2-key.pem ./deploy.sh
```

Le dépôt inclut aussi un `.gitignore` pour éviter de committer accidentellement `.env.production`, `terraform/terraform.tfvars` et les fichiers de state locaux.

## Outputs Terraform utiles

Quelques outputs importants après `terraform apply`:

- `app_url`
- `health_url`
- `elastic_ip`
- `secondary_elastic_ip`
- `ssh_command`
- `secondary_ssh_command`
- `external_dns_failover_targets`
- `cloudwatch_log_group_app`
- `cloudwatch_log_group_caddy`
- `ops_alerts_topic_arn`

Exemple:

```bash
terraform -chdir=terraform output app_url
terraform -chdir=terraform output external_dns_failover_targets
terraform -chdir=terraform output ssh_commands
```

## Vérifier les logs CloudWatch

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

## Sécurité et points d'attention

- SSH n'est autorisé que depuis `admin_cidr` au niveau AWS et UFW.
- HTTP et HTTPS restent exposés à Internet, car Caddy termine le trafic en frontal.
- `PRIVATE_KEY_PATH` doit rester sur le poste opérateur, jamais sur le dépôt.
- Les secrets applicatifs peuvent vivre dans un `.env` local et/ou dans SSM Parameter Store.
- Le modèle est simple mais ne remplace pas un vrai HA managé avec ALB, Auto Scaling, health checks distribués et certificats centralisés.

## Documentation complémentaire

- [Low-cost failover](docs/low-cost-failover.md)
- [Manual failover runbook](docs/manual-failover-runbook.md)