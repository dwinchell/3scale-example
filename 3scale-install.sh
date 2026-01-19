#!/bin/bash
set -euo pipefail
set -x

NAMESPACE=$(prefix="3scale" && printf "%s-%s\n" "$prefix" $(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5))
WILDCARD_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
DB_USER="system_user"
DB_PASS="system_password"
REDIS_PASS="redispw"
POSTGRES_TAG="latest"
REDIS_TAG="7-el9"

# --- Namespace Logic ---
echo "--- 1. Preparing Namespace ---"

echo
echo " Using Namespace: ${NAMESPACE}"
echo " Using Wildcard Domain: ${WILDCARD_DOMAIN}"
echo

if oc get project "$NAMESPACE" &>/dev/null; then
    echo "Error: Namespace '$NAMESPACE' already exists. Please choose a new name or delete the old one."
    exit 1
fi

oc create namespace "$NAMESPACE"
oc project "$NAMESPACE"

echo "--- 2. Installing 3scale Operator (2.16) ---"

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: 3scale-operatorgroup
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: 3scale-operator
  namespace: $NAMESPACE
spec:
  channel: threescale-2.16
  installPlanApproval: Automatic
  name: 3scale-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "--- 3. Waiting for Operator Pod ---"
# 1. Wait for the pod to actually exist in the API
until [ "$(oc get pods -n "$NAMESPACE" -l rht.subcomp=3scale_operator --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
    echo "Waiting for 3scale operator pod to be created..."
    sleep 5
done

# 2. Now wait for it to be Ready
while true; do
    # Use || echo "false" to ensure the variable assignment doesn't trigger set -e
    READY_STATUS=$(oc get pods -n "$NAMESPACE" -l rht.subcomp=3scale_operator -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    
    if [ "$READY_STATUS" == "true" ]; then
        echo "Operator is Ready!"
        break
    fi
    echo "Waiting for operator pod to reach Ready state..."
    sleep 5
done

echo "--- 4. Deploying Persistent Databases (PostgreSQL & Redis) ---"

# System Database
oc create deployment system-db-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:${POSTGRES_TAG}
oc set env deployment/system-db-manual POSTGRESQL_USER=$DB_USER POSTGRESQL_PASSWORD=$DB_PASS POSTGRESQL_DATABASE=system_db
oc set volume deployment/system-db-manual --add --name=system-db-data --type=pvc --claim-size=5Gi --mount-path=/var/lib/pgsql/data
oc expose deployment system-db-manual --port=5432

# Zync Database
oc create deployment zync-db-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:${POSTGRES_TAG}
oc set env deployment/zync-db-manual POSTGRESQL_USER=$DB_USER POSTGRESQL_PASSWORD=$DB_PASS POSTGRESQL_DATABASE=zync_db
oc set volume deployment/zync-db-manual --add --name=zync-db-data --type=pvc --claim-size=1Gi --mount-path=/var/lib/pgsql/data
oc expose deployment zync-db-manual --port=5432

# Redis
oc create deployment redis-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/redis:${REDIS_TAG}
oc set env deployment/redis-manual REDIS_PASSWORD=$REDIS_PASS
oc set volume deployment/redis-manual --add --name=redis-data --type=pvc --claim-size=1Gi --mount-path=/var/lib/redis/data
oc expose deployment redis-manual --port=6379

echo "--- Waiting for Database Pods to be Ready ---"
oc rollout status deployment/redis-manual --timeout=120s
oc rollout status deployment/system-db-manual --timeout=120s
oc rollout status deployment/zync-db-manual --timeout=120s

echo "--- 5. Creating Secrets for 3scale ---"

# 1. System Database
oc create secret generic system-database \
  --from-literal=URL=postgresql://$DB_USER:$DB_PASS@system-db-manual:5432/system_db

# 2. Zync Database (Needed for Operator Preflights)
oc create secret generic zync-queues-database \
  --from-literal=DATABASE_URL=postgresql://$DB_USER:$DB_PASS@zync-db-manual:5432/zync_db

# 3. Zync Token (Needed for system-app-pre and zync pods)
oc create secret generic zync \
  --from-literal=ZYNC_AUTHENTICATION_TOKEN=$(openssl rand -base64 32)

# 4. Redis
oc create secret generic system-redis --from-literal=URL=redis://:$REDIS_PASS@redis-manual:6379/0
oc create secret generic backend-redis \
  --from-literal=REDIS_STORAGE_URL=redis://:$REDIS_PASS@redis-manual:6379/1 \
  --from-literal=REDIS_QUEUES_URL=redis://:$REDIS_PASS@redis-manual:6379/2

echo "--- 6. Deploying APIManager ---"

cat <<EOF | oc apply -f -
apiVersion: apps.3scale.net/v1alpha1
kind: APIManager
metadata:
  name: apimanager-sample
spec:
  wildcardDomain: $WILDCARD_DOMAIN
  resourceRequirementsEnabled: false
  highAvailability:
    enabled: false
  externalComponents:
    system:
      database: true
      redis: true
    backend:
      redis: true
  system:
    fileStorage:
      persistentVolumeClaim: {}
EOF

echo "Project: $NAMESPACE"
echo "Domain: $WILDCARD_DOMAIN"

# Final sanity check to ensure the APIManager was accepted
sleep 5
oc get apimanager -o yaml -n ${NAMESPACE}

echo "--- 6.5 Waiting for Database Migrations (system-app-pre job) ---"
while true; do
    # Check if the Job object even exists first
    if ! oc get job system-app-pre -n "$NAMESPACE" &>/dev/null; then
        echo "Waiting for Job 'system-app-pre' to be created..."
        sleep 5
        continue
    fi

    # Query the status only after we know the job exists
    JOB_STATUS=$(oc get job system-app-pre -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "False")
    
    if [ "$JOB_STATUS" == "True" ]; then
        echo "Database migrations complete!"
        break
    fi

    # Get Pod phase for logging purposes
    POD_PHASE=$(oc get pods -n "$NAMESPACE" -l job-name=system-app-pre -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Starting")
    echo "Waiting for migrations to finish... (Job Status: InProgress, Pod Phase: $POD_PHASE)"
    sleep 10
done

# This label identifies the actual 3scale app components (Apicast, System, Backend, Zync)
APP_LABEL="rht.comp=3scale,rht.subcomp_t=application"

while true; do
    # Get the number of pods that are NOT ready
    NOT_READY=$(oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers 2>/dev/null | grep -v "1/1" | wc -l)

    # Get total count to ensure pods have actually been created by the operator
    TOTAL_PODS=$(oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers 2>/dev/null | wc -l)

    if [ "$TOTAL_PODS" -gt 0 ] && [ "$NOT_READY" -eq 0 ]; then
        echo "All 3scale application pods are Ready!"
        break
    fi

    echo "Waiting for $NOT_READY pods to initialize (Total application pods: $TOTAL_PODS)..."
    sleep 10
done

echo "--- 8. 3scale Installation Successful! ---"

# Retrieve the Admin Portal URL
ADMIN_URL=$(oc get route system-developer-console -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Extracting Admin Password..."
# Retry loop for the secret, as it can take a few seconds to populate after pods are 'Ready'
for i in {1..10}; do
    ADMIN_PASS=$(oc extract secret/system-seed -n "$NAMESPACE" --to=- --keys=ADMIN_PASSWORD 2>/dev/null || echo "")
    if [ -n "$ADMIN_PASS" ]; then
        break
    fi
    echo "Waiting for system-seed secret to populate..."
    sleep 5
done

echo "--------------------------------------------------"
echo "Admin Portal URL: https://$ADMIN_URL"
echo "Username: admin"
echo "Password: $ADMIN_PASS"
echo "--------------------------------------------------"
