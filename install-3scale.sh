#!/bin/bash
set -euo pipefail
# set -x # Uncomment for deep debugging

NAMESPACE=$(prefix="3scale" && printf "%s-%s\n" "$prefix" $(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5))
WILDCARD_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
DB_USER="system_user"
DB_PASS="system_password"
REDIS_PASS="redispw"
POSTGRES_TAG="latest"
REDIS_TAG="7-el9"
STORAGE_CLASS="azurefile-csi"

echo "--- 1. Preparing Namespace ---"
echo " Using Namespace: ${NAMESPACE}"
echo " Using Wildcard Domain: ${WILDCARD_DOMAIN}"

if oc get project "$NAMESPACE" &>/dev/null; then
    echo "Error: Namespace '$NAMESPACE' already exists."
    exit 1
fi

oc create namespace "$NAMESPACE"
oc project "$NAMESPACE"

echo "--- 2. Installing 3scale Operator ---"
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
until [ "$(oc get pods -n "$NAMESPACE" -l rht.subcomp=3scale_operator --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
    echo "Waiting for operator pod to be created..."
    sleep 5
done

while true; do
    READY_STATUS=$(oc get pods -n "$NAMESPACE" -l rht.subcomp=3scale_operator -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    if [ "$READY_STATUS" == "true" ]; then
        echo "Operator is Ready!"
        break
    fi
    sleep 5
done

echo "--- 4. Deploying Persistent Databases ---"
oc create deployment system-db-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:${POSTGRES_TAG}
oc set env deployment/system-db-manual POSTGRESQL_USER=$DB_USER POSTGRESQL_PASSWORD=$DB_PASS POSTGRESQL_DATABASE=system_db
oc set volume deployment/system-db-manual --add --name=system-db-data --type=pvc --claim-size=5Gi --mount-path=/var/lib/pgsql/data
oc expose deployment system-db-manual --port=5432

oc create deployment zync-db-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:${POSTGRES_TAG}
oc set env deployment/zync-db-manual POSTGRESQL_USER=$DB_USER POSTGRESQL_PASSWORD=$DB_PASS POSTGRESQL_DATABASE=zync_db
oc set volume deployment/zync-db-manual --add --name=zync-db-data --type=pvc --claim-size=1Gi --mount-path=/var/lib/pgsql/data
oc expose deployment zync-db-manual --port=5432

oc create deployment redis-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/redis:${REDIS_TAG}
oc set env deployment/redis-manual REDIS_PASSWORD=$REDIS_PASS
oc set volume deployment/redis-manual --add --name=redis-data --type=pvc --claim-size=1Gi --mount-path=/var/lib/redis/data
oc expose deployment redis-manual --port=6379

echo "--- Waiting for Database Rollouts ---"
oc rollout status deployment/redis-manual --timeout=120s
oc rollout status deployment/system-db-manual --timeout=120s
oc rollout status deployment/zync-db-manual --timeout=120s

echo "--- 5. Creating Secrets ---"
oc create secret generic system-database --from-literal=URL=postgresql://$DB_USER:$DB_PASS@system-db-manual:5432/system_db
oc create secret generic zync-queues-database --from-literal=DATABASE_URL=postgresql://$DB_USER:$DB_PASS@zync-db-manual:5432/zync_db
oc create secret generic zync --from-literal=ZYNC_AUTHENTICATION_TOKEN=$(openssl rand -base64 32)
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
    system: { database: true, redis: true }
    backend: { redis: true }
  system:
    fileStorage:
      persistentVolumeClaim:
        storageClassName: $STORAGE_CLASS
EOF

echo "--- 7. Waiting for Database Migrations (system-app-pre job) ---"
while true; do
    if ! oc get job system-app-pre -n "$NAMESPACE" &>/dev/null; then
        echo "Waiting for Job 'system-app-pre' to be created..."
        sleep 5
        continue
    fi

    JOB_STATUS=$(oc get job system-app-pre -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "False")
    if [ "$JOB_STATUS" == "True" ]; then
        echo "Database migrations complete!"
        break
    fi

    POD_PHASE=$(oc get pods -n "$NAMESPACE" -l job-name=system-app-pre -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Starting")
    echo "Waiting for migrations... (Pod Phase: $POD_PHASE)"
    sleep 10
done

echo "--- 8. Waiting for Application Pod Rollout ---"
APP_LABEL="rht.comp=3scale,rht.subcomp_t=application"
until [ "$(oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
    echo "Waiting for pods to appear..."
    sleep 10
done

while true; do
    NOT_READY=$(oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers | grep "Running" | grep -vE "1/1|2/2|3/3|4/4" | wc -l)
    if [ "$NOT_READY" -eq 0 ]; then
        echo "All application pods are Ready!"
        break
    fi
    echo "Waiting for $NOT_READY pods to initialize..."
    sleep 10
done

