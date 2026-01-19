#!/bin/bash

# --- Help Text Function ---
function usage() {
    echo "Usage: $0 <namespace> <wildcard_domain>"
    echo ""
    echo "Arguments:"
    echo "  namespace          The OpenShift project to create (must not exist)"
    echo "  wildcard_domain    The base domain for 3scale routes (e.g., apps.cluster.example.com)"
    echo ""
    echo "Example:"
    echo "  $0 my-3scale-test apps.cluster-1234.openshift.com"
    exit 1
}

# --- Argument Validation ---
if [ "$#" -ne 2 ]; then
    usage
fi

NAMESPACE=$1
WILDCARD_DOMAIN=$2
DB_USER="system_user"
DB_PASS="system_password"
REDIS_PASS="redispw"

# --- Namespace Logic ---
echo "--- 1. Preparing Namespace: $NAMESPACE ---"
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

echo "--- 3. Waiting for Operator Pod (rht.subcomp: 3scale_operator) ---"

# Loop until the pod exists and is Ready
while true; do
    READY_STATUS=$(oc get pods -n "$NAMESPACE" -l rht.subcomp=3scale_operator -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
    if [ "$READY_STATUS" == "true" ]; then
        break
    fi
    echo "Waiting for 3scale operator pod to be ready in $NAMESPACE..."
    sleep 5
done

echo "Operator is up! Provisioning database infrastructure..."

echo "--- 4. Deploying Persistent Databases (PostgreSQL & Redis) ---"

# System Database
oc create deployment system-db-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:7-el9
oc set env deployment/system-db-manual POSTGRESQL_USER=$DB_USER POSTGRESQL_PASSWORD=$DB_PASS POSTGRESQL_DATABASE=system_db
oc set volume deployment/system-db-manual --add --name=system-db-data --type=pvc --claim-size=5Gi --mount-path=/var/lib/pgsql/data
oc expose deployment system-db-manual --port=5432

# Zync Database
oc create deployment zync-db-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/postgresql:latest
oc set env deployment/zync-db-manual POSTGRESQL_USER=$DB_USER POSTGRESQL_PASSWORD=$DB_PASS POSTGRESQL_DATABASE=zync_db
oc set volume deployment/zync-db-manual --add --name=zync-db-data --type=pvc --claim-size=1Gi --mount-path=/var/lib/pgsql/data
oc expose deployment zync-db-manual --port=5432

# Redis
oc create deployment redis-manual --image=image-registry.openshift-image-registry.svc:5000/openshift/redis:latest
oc set env deployment/redis-manual REDIS_PASSWORD=$REDIS_PASS
oc set volume deployment/redis-manual --add --name=redis-data --type=pvc --claim-size=1Gi --mount-path=/var/lib/redis/data
oc expose deployment redis-manual --port=6379

echo "--- 5. Creating Secrets for 3scale ---"

oc create secret generic system-database --from-literal=URL=postgresql://$DB_USER:$DB_PASS@system-db-manual:5432/system_db
oc create secret generic system-redis    --from-literal=URL=redis://:$REDIS_PASS@redis-manual:6379/0
oc create secret generic zync --from-literal=DATABASE_URL=postgresql://$DB_USER:$DB_PASS@zync-db-manual:5432/zync_db

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
EOF

echo "--- Script Complete ---"
echo "Project: $NAMESPACE"
echo "Domain: $WILDCARD_DOMAIN"
echo "Monitor: oc get pods -w"

# Final sanity check to ensure the APIManager was accepted
sleep 5
oc get apimanager apimanager-sample
