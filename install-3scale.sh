#!/bin/bash
set -euo pipefail
set -x

# --- Defaults ---
NAMESPACE=$(prefix="3scale" && printf "%s-%s\n" "$prefix" $(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5))
WILDCARD_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
DB_USER="system_user"
DB_PASS="system_password"
REDIS_PASS="redispw"
POSTGRES_TAG="latest"
REDIS_TAG="7-el9"

# Default Storage Classes for ARO
DB_STORAGE_CLASS="managed-csi"    # Block storage for Databases (RWO)
SC_STORAGE_CLASS="azurefile-csi"  # File storage for 3scale System (RWX)

# --- Argument Parsing ---
while getopts "n:d:s:" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    d) DB_STORAGE_CLASS="$OPTARG" ;; # -d for Database storage class
    s) SC_STORAGE_CLASS="$OPTARG" ;; # -s for 3scale System storage class
    *) echo "Usage: $0 [-n <NAMESPACE>] [-d <DB_STORAGE_CLASS>] [-s <SC_STORAGE_CLASS>]"; exit 1 ;;
  esac
done

echo "--- 1. Preparing Namespace ---"
echo " Using Namespace: ${NAMESPACE}"
echo " Database Storage: ${DB_STORAGE_CLASS}"
echo " 3scale System Storage: ${SC_STORAGE_CLASS}"

if oc get project "$NAMESPACE" &>/dev/null; then
    oc project "$NAMESPACE"
else
    oc create namespace "$NAMESPACE"
    oc project "$NAMESPACE"
fi

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
# Loop uses rht.subcomp label to find the operator pod
until [ "$(oc get pods -n "$NAMESPACE" -l rht.subcomp=3scale_operator --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
    echo "Waiting for operator pod to be created..."
    sleep 10
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

# Create PVCs using DB_STORAGE_CLASS
oc apply -f - <<EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: system-db-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 5Gi } }
  storageClassName: $DB_STORAGE_CLASS
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: zync-db-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
  storageClassName: $DB_STORAGE_CLASS
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: redis-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
  storageClassName: $DB_STORAGE_CLASS
EOF

# Deploy All Databases
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: system-db-manual
spec:
  selector:
    matchLabels:
      app: system-db-manual
  template:
    metadata:
      labels:
        app: system-db-manual
    spec:
      containers:
      - name: postgresql
        image: image-registry.openshift-image-registry.svc:5000/openshift/postgresql:${POSTGRES_TAG}
        env:
        - name: POSTGRESQL_USER
          value: "$DB_USER"
        - name: POSTGRESQL_PASSWORD
          value: "$DB_PASS"
        - name: POSTGRESQL_DATABASE
          value: "system_db"
        - name: POSTGRESQL_SKIP_CHMOD_CHOWN
          value: "true"
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: system-db-data
          mountPath: /var/lib/pgsql/data
      volumes:
      - name: system-db-data
        persistentVolumeClaim:
          claimName: system-db-data
---
apiVersion: v1
kind: Service
metadata:
  name: system-db-manual
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: system-db-manual
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zync-db-manual
spec:
  selector:
    matchLabels:
      app: zync-db-manual
  template:
    metadata:
      labels:
        app: zync-db-manual
    spec:
      containers:
      - name: postgresql
        image: image-registry.openshift-image-registry.svc:5000/openshift/postgresql:${POSTGRES_TAG}
        env:
        - name: POSTGRESQL_USER
          value: "$DB_USER"
        - name: POSTGRESQL_PASSWORD
          value: "$DB_PASS"
        - name: POSTGRESQL_DATABASE
          value: "zync_db"
        - name: POSTGRESQL_SKIP_CHMOD_CHOWN
          value: "true"
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: zync-db-data
          mountPath: /var/lib/pgsql/data
      volumes:
      - name: zync-db-data
        persistentVolumeClaim:
          claimName: zync-db-data
---
apiVersion: v1
kind: Service
metadata:
  name: zync-db-manual
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: zync-db-manual
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-manual
spec:
  selector:
    matchLabels:
      app: redis-manual
  template:
    metadata:
      labels:
        app: redis-manual
    spec:
      containers:
      - name: redis
        image: image-registry.openshift-image-registry.svc:5000/openshift/redis:${REDIS_TAG}
        env:
        - name: REDIS_PASSWORD
          value: "$REDIS_PASS"
        ports:
        - containerPort: 6379
        volumeMounts:
        - name: redis-data
          mountPath: /var/lib/redis/data
      volumes:
      - name: redis-data
        persistentVolumeClaim:
          claimName: redis-data
---
apiVersion: v1
kind: Service
metadata:
  name: redis-manual
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: redis-manual
EOF


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
# Using SC_STORAGE_CLASS specifically for the shared RWX storage
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
        storageClassName: $SC_STORAGE_CLASS
EOF

echo "--- 7. Waiting for Database Migrations (system-app-pre job) ---"
# Waits for migration job to complete before checking pods
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
    # Filters by "Running" status and verifies ready replicas
    NOT_READY=$(oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers | grep "Running" | grep -vE "1/1|2/2|3/3|4/4" | wc -l)
    if [ "$NOT_READY" -eq 0 ]; then
        echo "All application pods are Ready!"
        break
    fi
    echo "Waiting for $NOT_READY pods to initialize..."
    sleep 10
done

# --- 9. Access Credentials ---
echo "--- 9. Retrieving Access Credentials ---"

# Wait for the system-seed secret to be generated by the operator
echo "Waiting for system-seed secret..."
until oc get secret system-seed -n "$NAMESPACE" &>/dev/null; do
    sleep 5
done

# 1. Retrieve the Admin Password
ADMIN_PASS=$(oc extract secret/system-seed -n "$NAMESPACE" --to=- --keys=ADMIN_PASSWORD 2>/dev/null)

# 2. Retrieve the Admin Portal URL
# We wait for the route to be admitted by the ingress controller
echo "Waiting for Admin Portal route..."
until [ "$(oc get routes -n "$NAMESPACE" -l "zync.3scale.net/route-type=master-portal" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)" != "" ]; do
    sleep 5
done
MASTER_URL=$(oc get routes -n "$NAMESPACE" -l "zync.3scale.net/route-type=master-portal" -o jsonpath='{.items[0].spec.host}')

# 3. Retrieve the Provider Key via internal API
echo "Retrieving Provider Key from internal system-master API..."
# This uses an ephemeral pod to bypass any external networking/cert issues
PROVIDER_KEY=$(oc run fetch-key-$(date +%s) --image=registry.redhat.io/rhel8/support-tools --rm -it --restart=Never --quiet -- \
  curl -s -k -u "master:$ADMIN_PASS" "http://system-master.$NAMESPACE.svc.cluster.local:3000/admin/api/account/provider_key.xml" | \
  grep -oPm1 "(?<=<provider_key>)[^<]+" || echo "Manual retrieval required")

echo ""
echo "--------------------------------------------------"
echo "3scale Installation Complete!"
echo "--------------------------------------------------"
echo "Admin Portal URL: https://$MASTER_URL"
echo "Username:         master"
echo "Password:         $ADMIN_PASS"
echo ""
echo "Provider API Key: $PROVIDER_KEY"
echo "--------------------------------------------------"
echo ""
echo "Next Step: Run your APIcast install script:"
echo "./install-apicast.sh -k $PROVIDER_KEY -n apicast-prod -e production"

