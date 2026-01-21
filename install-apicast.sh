#!/bin/bash
set -euo pipefail

# --- Argument Parsing ---
ADMIN_PORTAL_PROVIDER_KEY=""

while getopts "k:" opt; do
  case $opt in
    k) ADMIN_PORTAL_PROVIDER_KEY="$OPTARG" ;;
    *) echo "Usage: $0 -k <ADMIN_PORTAL_PROVIDER_KEY>"; exit 1 ;;
  esac
done

if [ -z "$ADMIN_PORTAL_PROVIDER_KEY" ]; then
    echo "Error: -k <ADMIN_PORTAL_PROVIDER_KEY> is required."
    exit 1
fi

NAMESPACE=$(prefix="apicast" && printf "%s-%s\n" "$prefix" $(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5))
APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
ADMIN_PORTAL_SECRET=admin-portal-creds
ADMIN_PORTAL_DOMAIN="3scale-admin.${APPS_DOMAIN}"
ADMIN_PORTAL_URL="https://${ADMIN_PORTAL_PROVIDER_KEY}@${ADMIN_PORTAL_DOMAIN}/"

echo "--- 1. Preparing Namespace ---"

if oc get project "$NAMESPACE" &>/dev/null; then
    echo "Error: Namespace '$NAMESPACE' already exists."
    exit 1
fi

oc create namespace "$NAMESPACE"
oc project "$NAMESPACE"

echo " Using Namespace: ${NAMESPACE}"

echo "--- 2. Installing APICast Operator ---"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: APIcast.v1alpha1.apps.3scale.net
  name: apicast
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
  upgradeStrategy: Default
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/apicast-operator.apicast: ""
  name: apicast-operator
  namespace: $NAMESPACE
spec:
  channel: threescale-2.16
  installPlanApproval: Automatic
  name: apicast-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "--- 3. Waiting for Operator Pod ---"
until [ "$(oc get pods -n "$NAMESPACE" -l rht.subcomp=apicast_operator --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
    echo "Waiting for operator pod to be created..."
    sleep 5
done

while true; do
    READY_STATUS=$(oc get pods -n "$NAMESPACE" -l rht.subcomp=apicast_operator -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    if [ "$READY_STATUS" == "true" ]; then
        echo "Operator is Ready!"
        break
    fi
    sleep 5
done

echo "--- 4. Creating Admin Portal Secret ---"
oc create secret generic "${ADMIN_PORTAL_SECRET}" --from-literal=AdminPortalURL="${ADMIN_PORTAL_URL}"

echo "--- 5. Deploying APIcast CR ---"
cat <<EOF | oc apply -f -
apiVersion: apps.3scale.net/v1alpha1
kind: APIcast
metadata:
  name: apicast
  namespace: $NAMESPACE
spec:
  adminPortalCredentialsRef:
    name: $ADMIN_PORTAL_SECRET
  logLevel: debug
  pathRoutingEnabled: true
EOF

