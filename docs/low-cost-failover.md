# Low-cost two-node design for uty-api

## Intent

Le but est de garder une infrastructure tres simple a operer et peu couteuse, tout en reduisant les points de defaillance les plus evidents. Le design reste volontairement plus leger qu'une pile ALB + Auto Scaling, mais chaque noeud peut desormais servir l'application et chaque Caddy sait router vers le backend local et distant.

## Architecture exacte

- 1 VPC unique
- 2 subnets publics
- 1 IGW et 1 route table publique
- 1 security group partage
- 1 instance primaire `uty-api`
- 1 instance secondaire `uty-api-secondary`
- 1 Elastic IP par noeud
- 1 IAM role EC2 compatible SSM et CloudWatch
- 2 log groups par noeud: `app` et `caddy`
- 2 alarmes CloudWatch par noeud
- 1 SNS topic optionnel
- 1 map optionnelle de parametres SSM SecureString

## Pourquoi ce design reste low-cost

Le cout reste contenu parce que:

- il n'y a pas d'ALB
- il n'y a pas de NAT Gateway
- il n'y a pas d'Auto Scaling Group
- il n'y a pas de bastion dedie
- la taille par defaut reste `t3.micro`
- le trafic Internet passe directement vers les instances publiques

Compromis acceptes:

- le routage public depend toujours d'un DNS externe
- il n'y a pas de health-based routing natif cote DNS AWS
- il n'y a pas de terminaison TLS centralisee
- il n'y a pas de coordination globale des certificats TLS entre noeuds sans stockage partage Caddy ou challenge DNS

## Role des Elastic IPs

Les Elastic IPs jouent trois roles importants:

- elles donnent une cible DNS stable pour chaque noeud public
- elles permettent soit un mode a 2 `A` records, soit un drain manuel simple en retirant un noeud du DNS
- elles evitent de dependre de l'adresse publique dynamique d'EC2

En mode nominal:

- vous pouvez soit publier les 2 EIPs en parallele, soit n'en publier qu'une seule si vous restez en mode plus conservateur
- meme avec un seul `A` record public, Caddy peut continuer a servir via l'autre backend applicatif si le backend local tombe

## Strategie DNS externe

Le DNS n'est pas gere dans AWS. Ce depot suppose donc:

- un provider DNS externe pouvant idealement publier 2 `A` records pour le domaine applicatif
- un TTL court, recommande a `60` secondes
- une capacite operateur a retirer rapidement une cible DNS degradee en incident

Exemples de strategies possibles chez un provider externe:

- deux `A` records actifs en parallele
- un simple `A` record modifie manuellement si vous gardez un seul ingress public
- un mode failover ou health-checked du provider DNS si celui-ci existe, mais pilote hors AWS

## Modele de trafic

- Chaque noeud execute Caddy et l'application NestJS.
- Chaque Caddy peut joindre son backend local via Docker et le backend distant via l'IP privee EC2 sur le port `3000`.
- Si les 2 Elastic IPs sont publiees dans le DNS, le trafic peut entrer par les 2 noeuds.
- Si un backend applicatif devient indisponible, Caddy peut continuer a router vers le backend sain.
- Si un noeud public complet devient indisponible, retirer son IP du DNS reste l'action operatoire la plus simple.

Ce modele fonctionne bien pour une API stateless ou quasi-stateless. Si l'application porte de l'etat local non replique, ce design ne suffit pas a garantir une reprise propre.

## Strategie de deploiement Docker Hub

Le depot backend n'est jamais clone sur les serveurs. Le flux attendu est:

1. build et push de l'image NestJS vers Docker Hub
2. mise a jour de `app_image_tag` ou redeploiement du tag cible
3. `deploy.sh` execute Terraform puis Ansible
4. Ansible fait `docker compose pull app` puis `docker compose up -d --remove-orphans`

## Logs et observabilite

Chaque conteneur envoie ses logs vers CloudWatch Logs via `awslogs`.

Groupes de logs:

- primaire:
  - `/uty-api/app`
  - `/uty-api/caddy`
- secondaire:
  - `/uty-api-secondary/app`
  - `/uty-api-secondary/caddy`

CloudWatch couvre aussi deux alarmes EC2 par noeud. Le `StatusCheckFailed_System` tente une recuperation EC2 native. Le `StatusCheckFailed_Instance` sert d'alerte operateur.

## Limites HTTPS avec Caddy sans ALB

Quand `domain_name` est configure, Caddy gere automatiquement les certificats sur chaque instance qui recoit le trafic. Dans un modele a plusieurs noeuds sans ALB ni stockage partage Caddy:

- chaque noeud peut tenter d'emettre ou renouveler un certificat pour le meme domaine
- avec 2 `A` records publics, le challenge ACME peut etre plus delicat qu'avec une terminaison TLS centralisee
- si vous utilisez HTTP-01 ou TLS-ALPN-01, la robustesse TLS depend du comportement de votre DNS externe et du timing de validation
- pour un fonctionnement vraiment robuste a plusieurs noeuds, un challenge DNS ou un stockage partage Caddy est preferable

Consequence operationnelle:

- le HTTP interne et le failover backend sont ameliores, mais la gestion des certificats reste moins robuste qu'avec ALB + ACM
- gardez un TTL bas, testez regulierement le comportement DNS et envisagez un challenge DNS ou un stockage partage Caddy si vous voulez un vrai multi-ingress HTTPS durable

## Securite

- Security Group: SSH seulement depuis `admin_cidr`, HTTP/HTTPS publics, egress ouvert
- port `3000` ouvert uniquement entre instances partageant le security group
- UFW: meme politique cote OS
- IMDSv2 requis sur les instances
- IAM minimal pour SSM et CloudWatch Agent policy
- pas de port applicatif `3000` expose a Internet, seulement au reseau prive entre noeuds
- reverse proxy Caddy en frontal

## Quand faire evoluer ce design

Il faut envisager ALB + ACM + Auto Scaling ou ECS/Fargate si vous avez besoin de:

- failover automatique
- certificats TLS centralises sans dependance a chaque noeud
- blue/green ou rolling deploys plus avances
- separation reseau plus stricte avec subnets prives
- metriques et health checks plus fins
