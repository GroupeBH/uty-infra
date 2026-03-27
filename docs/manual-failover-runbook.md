# Traffic drain and failover runbook for uty-api

## Scope

Ce runbook sert a retirer un noeud degrade du trafic public, a continuer le service sur le noeud restant, puis eventuellement a reintroduire le noeud repare.

## Pre-requis

- acces AWS valide
- acces au provider DNS externe
- `terraform output` disponible localement
- acces SSH aux deux instances
- connaissance du TTL DNS courant, idealement `60s`

## Rappels

- chaque noeud execute Caddy et la meme application
- Caddy peut router vers le backend local et le backend distant
- si votre DNS externe le permet, vous pouvez publier les 2 Elastic IPs en parallele
- si vous restez avec un seul `A` record public, ce runbook revient a basculer ce record entre les 2 noeuds

## Etape 1: qualifier l'incident

Verifier les outputs utiles:

```bash
terraform -chdir=terraform output elastic_ip
terraform -chdir=terraform output secondary_elastic_ip
terraform -chdir=terraform output health_url
terraform -chdir=terraform output external_dns_failover_targets
terraform -chdir=terraform output external_dns_active_active_targets
```

Verifier l'etat AWS:

```bash
aws ec2 describe-instance-status --region us-east-1 --include-all-instances
aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix uty-api
```

Tester la sante HTTP:

```bash
curl -i http://<primary_eip>/health
curl -i http://<secondary_eip>/health
curl -i https://api.example.com/health
```

Si le domaine est en HTTPS, gardez en tete que Caddy multi-noeud sans stockage partage reste moins previsible qu'une terminaison TLS centralisee.

## Etape 2: identifier le noeud a retirer ou a promouvoir

SSH sur le noeud qui doit continuer a porter le trafic:

```bash
ssh -i ~/.ssh/my-ec2-key.pem ubuntu@<healthy_eip>
```

Puis:

```bash
cd /opt/nestjs-caddy
docker compose ps
docker compose logs app --tail=100
docker compose logs caddy --tail=100
docker inspect nestjs-app
curl -i http://127.0.0.1:3000/health
```

Le noeud sain doit repondre localement et continuer a voir l'autre backend si celui-ci est encore partiellement disponible.

## Etape 3: mettre a jour le DNS externe

Choisir la strategie adaptee a votre mode DNS:

- si vous avez 2 `A` records actifs, retirez l'IP du noeud degrade
- si vous avez un seul `A` record, pointez-le vers l'Elastic IP du noeud sain

Regles d'exploitation:

- garder uniquement des cibles saines dans le DNS
- conserver un TTL bas
- documenter l'heure exacte du drain ou de la bascule

Apres modification DNS, verifier:

```bash
dig +short api.example.com
curl -i https://api.example.com/health
```

Si HTTPS ne repond pas immediatement, attendre la fenetre de propagation et verifier l'etat des certificats sur le noeud qui recoit le trafic.

## Etape 4: stabiliser apres changement de trafic

Surveiller:

```bash
aws logs tail /uty-api/app --follow --region us-east-1
aws logs tail /uty-api/caddy --follow --region us-east-1
aws logs tail /uty-api-secondary/app --follow --region us-east-1
aws logs tail /uty-api-secondary/caddy --follow --region us-east-1
```

Controler aussi les metriques EC2 et les alarmes CloudWatch.

## Etape 5: communiquer l'etat

Partager au minimum:

- heure de debut d'incident
- raison du drain ou du failover
- cible ou cibles DNS restantes
- validation du healthcheck cote noeud sain
- statut TLS si domaine HTTPS

## Reintroduction du noeud repare

Une fois le noeud repare:

1. verifier le noeud en direct par son EIP
2. redeployer si necessaire avec `deploy.sh`
3. controler `docker compose ps`, logs et healthcheck local
4. remettre son IP dans le DNS si vous utilisez 2 `A` records, ou rebasculer le `A` record unique si c'est votre strategie
5. reverifier le domaine et les logs applicatifs

Commandes utiles sur un noeud:

```bash
ssh -i ~/.ssh/my-ec2-key.pem ubuntu@<node_eip>
cd /opt/nestjs-caddy
docker compose pull app
docker compose up -d --remove-orphans
docker compose ps
curl -i http://127.0.0.1:3000/health
```

## Debug rapide

Terraform:

```bash
terraform -chdir=terraform output
terraform -chdir=terraform state list
```

Ansible:

```bash
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml --syntax-check
```

Docker sur une instance:

```bash
cd /opt/nestjs-caddy
docker compose ps
docker compose logs app --tail=100
docker compose logs caddy --tail=100
docker inspect nestjs-app
```

Systeme:

```bash
systemctl status docker
sudo ufw status verbose
journalctl -u docker --no-pager -n 100
```

## Ce que ce runbook ne fait pas

- pas de failover global automatique
- pas de fencing applicatif avance
- pas de synchronisation de donnees locales
- pas de garantie TLS multi-noeud equivalente a ALB + ACM sans preparation specifique

C'est un runbook volontairement simple et robuste pour un modele low-cost pilote par DNS externe.
