# Manual failover runbook for uty-api

## Scope

Ce runbook sert à basculer le trafic du primaire vers le secondaire, puis éventuellement à revenir sur le primaire après rétablissement.

## Pré-requis

- accès AWS valide
- accès au provider DNS externe
- `terraform output` disponible localement
- accès SSH aux deux instances
- connaissance du TTL DNS courant, idéalement `60s`

## Rappels

- en nominal, le DNS pointe vers l'Elastic IP primaire
- le secondaire reste en standby
- les deux nœuds sont déployés avec la même application, mais un seul doit recevoir le trafic public normal

## Étape 1: qualifier l'incident

Vérifier les outputs utiles:

```bash
terraform -chdir=terraform output elastic_ip
terraform -chdir=terraform output secondary_elastic_ip
terraform -chdir=terraform output health_url
terraform -chdir=terraform output external_dns_failover_targets
```

Vérifier l'état AWS:

```bash
aws ec2 describe-instance-status --region us-east-1 --include-all-instances
aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix uty-api
```

Tester la santé HTTP:

```bash
curl -i http://<primary_eip>/health
curl -i http://<secondary_eip>/health
curl -i https://api.example.com/health
```

Si le domaine est en HTTPS, gardez en tête que le secondaire peut avoir besoin de reprendre le certificat après bascule DNS.

## Étape 2: valider le secondaire avant la bascule

SSH sur le secondaire:

```bash
ssh -i ~/.ssh/my-ec2-key.pem ubuntu@<secondary_eip>
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

Le conteneur `nestjs-app` doit être `running`, avec un état `healthy` si l'image définit un healthcheck, sinon `running` sans healthcheck reste acceptable dans ce design.

## Étape 3: basculer le DNS externe

Mettre à jour le `A` record du domaine pour pointer vers l'Elastic IP secondaire.

Règles d'exploitation:

- ne garder qu'une seule cible active à la fois
- conserver un TTL bas
- documenter l'heure exacte de la bascule

Après modification DNS, vérifier:

```bash
dig +short api.example.com
curl -i https://api.example.com/health
```

Si HTTPS ne répond pas immédiatement, attendre la fenêtre de propagation et laisser Caddy finaliser le certificat sur le secondaire.

## Étape 4: stabiliser après failover

Surveiller:

```bash
aws logs tail /uty-api-secondary/app --follow --region us-east-1
aws logs tail /uty-api-secondary/caddy --follow --region us-east-1
```

Contrôler aussi les métriques EC2 et les alarmes CloudWatch.

## Étape 5: communiquer l'état

Partager au minimum:

- heure de début d'incident
- raison du failover
- nouvelle cible DNS
- validation du healthcheck côté secondaire
- statut TLS si domaine HTTPS

## Failback vers le primaire

Une fois le primaire corrigé:

1. vérifier le primaire en direct par son EIP
2. redéployer si nécessaire avec `deploy.sh`
3. contrôler `docker compose ps`, logs et healthcheck local
4. rebasculer le DNS externe vers l'Elastic IP primaire
5. revérifier le domaine et les logs applicatifs

Commandes utiles sur le primaire:

```bash
ssh -i ~/.ssh/my-ec2-key.pem ubuntu@<primary_eip>
cd /opt/nestjs-caddy
docker compose pull app
docker compose up -d --remove-orphans
docker compose ps
curl -i http://127.0.0.1:3000/health
```

## Débug rapide

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

Système:

```bash
systemctl status docker
sudo ufw status verbose
journalctl -u docker --no-pager -n 100
```

CloudWatch Logs:

```bash
aws logs tail /uty-api/app --follow --region us-east-1
aws logs tail /uty-api-secondary/app --follow --region us-east-1
```

## Ce que ce runbook ne fait pas

- pas de failover automatique
- pas de fencing applicatif avancé
- pas de synchronisation de données locales
- pas de garantie TLS instantanée sur le nœud passif sans préparation spécifique

C'est un runbook volontairement simple et robuste pour un modèle low-cost.