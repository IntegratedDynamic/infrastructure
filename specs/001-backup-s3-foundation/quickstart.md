# Quickstart & Validation Guide: Backup Storage Foundation

**Variables**: [contracts/terraform-interface.md](contracts/terraform-interface.md)
**Data model**: [data-model.md](data-model.md)

---

## Provision (dev)

```bash
terraform -chdir=03-backup/scaleway init
terraform -chdir=03-backup/scaleway workspace select -or-create dev
terraform -chdir=03-backup/scaleway plan -var-file=env/dev.tfvars
terraform -chdir=03-backup/scaleway apply -var-file=env/dev.tfvars -auto-approve
```

---

## Vérifier que le bucket existe

```bash
scw object bucket get backup-dev-id --region fr-par
```

Sortie attendue : métadonnées du bucket (region, endpoint, date de création). Une erreur 404 indique que le bucket n'a pas été créé.

---

## Valider l'accès workload depuis le cluster (test local)

Ce test valide le chemin complet : credentials Terraform → Secret Kubernetes → pod → S3.
Il s'exécute manuellement contre le cluster local (minikube) ou Scaleway.

**Étape 1 — Récupérer les credentials depuis les outputs Terraform**

```bash
ACCESS_KEY=$(terraform -chdir=03-backup/scaleway output -raw workload_access_key)
# La secret key n'est pas surfacée en output — la lire depuis Infisical :
SECRET_KEY=$(infisical secrets get BACKUP_SECRET_KEY --path /backup/dev --env staging --plain)
```

**Étape 2 — Créer le Secret Kubernetes (bypass ESO pour le test local)**

```bash
kubectl create namespace backup --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic backup-workload-credentials \
  --from-literal=access_key="$ACCESS_KEY" \
  --from-literal=secret_key="$SECRET_KEY" \
  --namespace backup
```

**Étape 3 — Lancer le Job de validation**

```bash
kubectl apply -f specs/001-backup-s3-foundation/test-job.yaml
kubectl wait --for=condition=complete job/backup-probe --namespace backup --timeout=60s
kubectl logs job/backup-probe --namespace backup
```

Sortie attendue dans les logs : `upload: /tmp/probe.txt to s3://backup-dev-id/probe/...`

**Étape 4 — Nettoyage**

```bash
kubectl delete job backup-probe --namespace backup
kubectl delete secret backup-workload-credentials --namespace backup
```

Le Job YAML (`test-job.yaml`) est colocalisé avec cette spec. En production, le workload réel remplace ce Job et ses credentials viennent d'ESO (pas d'un Secret créé manuellement).

---

## FR-016 — gate de validation lifecycle

```bash
terraform -chdir=03-backup/scaleway plan \
  -var-file=env/dev.tfvars \
  -var="cold_storage_enabled=true" \
  -var="cold_storage_transition_days=365" \
  -var="retention_days=365"
# Attendu : Error: cold_storage_transition_days must be strictly less than retention_days
```

---

## Note — CI

L'intégration CI du test cluster (Job Kubernetes automatisé dans le workflow backup) est hors scope de cette feature. Le `scw object bucket get` post-apply dans le workflow CI est le seul check automatisé.
