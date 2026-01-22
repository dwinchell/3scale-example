#!/bin/bash
set -euo pipefail
#set -x

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
        sleep 10
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

# Wait for at least one pod to be present
until oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers 2>/dev/null | grep -q .; do
    echo "Waiting for application pods to be created..."
    sleep 10
done

# Wait for all created pods to be Ready
while true; do
    # Capture the list of pods that are NOT Ready (excluding completed jobs)
    # We use '|| true' so the script doesn't exit if grep finds nothing
    PENDING_PODS=$(oc get pods -n "$NAMESPACE" -l "$APP_LABEL" --no-headers 2>/dev/null | grep -v "Completed" | grep -vE "1/1|2/2|3/3|4/4" || true)

    # Count the lines in the variable. If variable is empty, count is 0.
    if [ -z "$PENDING_PODS" ]; then
        NOT_READY_COUNT=0
    else
        NOT_READY_COUNT=$(echo "$PENDING_PODS" | wc -l)
    fi

    if [ "$NOT_READY_COUNT" -eq 0 ]; then
        echo "All application pods are Ready!"
        break
    fi
    
    echo "Waiting for $NOT_READY_COUNT pod(s) to initialize..."
    sleep 10
done

echo "3Scale installation complete!"

# --- 9. Access Information ---
echo "--- 9. Retrieving Credentials ---"

# Retrieve the credentials needed for manual login
# We wait for the secret to ensure the operator has finished seeding the data
until oc get secret system-seed -n "$NAMESPACE" &>/dev/null; do
    echo "Waiting for system-seed secret..."
    sleep 5
done
ADMIN_PASS=$(oc extract secret/system-seed -n "$NAMESPACE" --to=- --keys=ADMIN_PASSWORD 2>/dev/null)

# Improved Route retrieval with wait loop to prevent jsonpath index errors
echo "Waiting for Admin Portal route to be created and labeled..."
while true; do
    # Check if the route exists and has a non-empty host
    ADMIN_URL=$(oc get routes -n "$NAMESPACE" -l "zync.3scale.net/route-to=system-provider" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")

    if [ -n "$ADMIN_URL" ]; then
        break
    fi
    echo "Still waiting for Admin Portal route..."
    sleep 10
done

echo "--------------------------------------------------"
echo "3scale is now installed!"
echo "--------------------------------------------------"
echo "Admin Portal: https://$ADMIN_URL"
echo "Username:     admin"
echo "Password:     $ADMIN_PASS"
echo "--------------------------------------------------"
echo ""
echo "Action Required: Log in to the Admin Portal above."
echo "1. Dismiss the getting started tour by selecting the X icon to the top right."
echo "2. Select the dropdown in the top navigation that initially says 'Dashboard'."
echo "3. Select 'Account Settings'"
echo "4. Copy the Provider Key in large text. DO NOT include trailing spaces."
echo "5. Use the Provider Key to run ./install-apicast.sh. See README.md"
echo "--------------------------------------------------"

