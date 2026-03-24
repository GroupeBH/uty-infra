# Low-cost active-passive design for uty-api

## Intent

Le but est de garder une infrastructure très simple à opérer et peu coûteuse, tout en évitant le point de défaillance unique le plus évident: l'instance applicative. On accepte donc un failover manuel DNS au lieu d'un basculement automatique via ALB, Route 53 health checks ou Auto Scaling.

## Architecture exacte

- 1 VPC unique en `us-east-1`
- 2 subnets publics
- 1 IGW et 1 route table publique
- 1 security group partagé
- 1 instance primaire `uty-api`
- 1 instance secondaire `uty-api-secondary`
- 1 Elastic IP par nœud
- 1 IAM role EC2 compatible SSM et CloudWatch
- 2 log groups par nœud: `app` et `caddy`
- 2 alarmes CloudWatch par nœud:
  - `StatusCheckFailed_System` avec recovery EC2
  - `StatusCheckFailed_Instance`
- 1 SNS topic optionnel
- 1 map optionnelle de paramètres SSM SecureString

## Pourquoi ce design est low-cost

Le coût reste contenu parce que:

- il n'y a pas d'ALB
- il n'y a pas de NAT Gateway
- il n'y a pas d'Auto Scaling Group
- il n'y a pas de bastion dédié
- la taille par défaut reste `t3.micro`
- le trafic Internet passe directement vers les instances publiques

Tradeoffs assumés:

- le failover est manuel
- il n'y a pas de health-based routing natif côté DNS AWS
- il n'y a pas de terminaison TLS centralisée
- le standby coûte une petite base EC2 + EIP + stockage, mais moins qu'une pile HA complète

## Rôle des Elastic IPs

Les Elastic IPs jouent trois rôles importants:

- elles donnent une cible DNS stable pour le primaire et le secondaire
- elles rendent le runbook de failover très simple: changer le `A` record vers l'IP secondaire
- elles évitent de dépendre de l'adresse publique dynamique d'EC2

En mode nominal:

- le DNS externe pointe vers l'EIP du primaire
- l'EIP du secondaire reste connue mais non utilisée publiquement

## Stratégie DNS externe

Le DNS n'est pas géré dans AWS. Ce dépôt suppose donc:

- un `A` record externe pour le domaine applicatif
- un TTL court, recommandé à `60` secondes
- une capacité opérateur à modifier le record rapidement en incident

Exemples de stratégies possibles chez un provider externe:

- un simple `A` record modifié manuellement
- deux enregistrements documentés, dont un seul actif à la fois
- un mode failover du provider DNS si celui-ci existe, mais piloté hors AWS

## Modèle de trafic

- Le primaire reçoit le trafic normal.
- Le secondaire est un standby prêt à être promu par bascule DNS.
- Les deux nœuds peuvent techniquement servir l'API, mais le design opérationnel impose un seul point de trafic public à la fois.

Ce modèle fonctionne bien pour une API stateless ou quasi-stateless. Si l'application porte de l'état local non répliqué, ce design ne suffit pas à garantir une reprise propre.

## Stratégie de déploiement Docker Hub

Le dépôt backend n'est jamais cloné sur les serveurs. Le flux attendu est:

1. build et push de l'image NestJS vers Docker Hub
2. mise à jour de `app_image_tag` ou redéploiement du tag cible
3. `deploy.sh` exécute Terraform puis Ansible
4. Ansible fait `docker compose pull app` puis `docker compose up -d --remove-orphans`

Avantages:

- serveurs plus simples
- surface d'attaque plus faible qu'un `git clone` + build local
- déploiement reproductible et aligné sur le tag d'image

## Logs et observabilité

Chaque conteneur envoie ses logs vers CloudWatch Logs via `awslogs`.

Groupes de logs:

- primaire:
  - `/uty-api/app`
  - `/uty-api/caddy`
- secondaire:
  - `/uty-api-secondary/app`
  - `/uty-api-secondary/caddy`

CloudWatch couvre aussi deux alarmes EC2 par nœud. Le `StatusCheckFailed_System` tente une récupération EC2 native. Le `StatusCheckFailed_Instance` sert d'alerte opérateur.

## Secrets et configuration applicative

Deux modèles sont prévus:

- fichier `.env` local copié par Ansible
- paramètres SSM SecureString créés par Terraform

Le design ne force pas l'un ou l'autre. Pour un runtime NestJS classique, le `.env` reste le plus simple si l'image sait le consommer.

## Limites HTTPS avec Caddy sans ALB

C'est le point le plus important à comprendre.

Quand `domain_name` est configuré, Caddy gère automatiquement les certificats sur l'instance qui reçoit le trafic. Dans un modèle active-passive sans ALB:

- le primaire obtient normalement le certificat tant que le DNS pointe sur lui
- le secondaire peut ne pas obtenir ou renouveler son certificat tant que le DNS ne pointe pas vers son EIP
- lors d'un failover, il peut y avoir un délai pendant lequel Caddy doit émettre ou renouveler le certificat sur le secondaire
- si vous utilisez un challenge HTTP-01/TLS-ALPN-01, l'instance passive ne peut pas préchauffer le certificat sans recevoir réellement le trafic du domaine

Conséquence opérationnelle:

- le failover HTTPS n'est pas aussi fluide qu'avec un ALB ou un certificate manager centralisé
- pour réduire le risque, gardez un TTL bas, testez régulièrement le basculement et envisagez un challenge DNS si votre provider externe et votre stratégie Caddy le permettent dans le futur

## Sécurité

- Security Group: SSH seulement depuis `admin_cidr`, HTTP/HTTPS publics, egress ouvert
- UFW: même politique côté OS
- IMDSv2 requis sur les instances
- IAM minimal pour SSM et CloudWatch Agent policy
- pas de port applicatif `3000` exposé à Internet, seulement `127.0.0.1:3000`
- reverse proxy Caddy en frontal

## Quand faire évoluer ce design

Il faut envisager ALB + ACM + Auto Scaling ou ECS/Fargate si vous avez besoin de:

- failover automatique
- certificats TLS centralisés sans dépendance au nœud actif
- blue/green ou rolling deploys plus avancés
- séparation réseau plus stricte avec subnets privés
- métriques et health checks plus fins