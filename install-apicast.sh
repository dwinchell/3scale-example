#!/bin/bash
set -euo pipefail

# --- Defaults ---
# Randomly generated default like before
NAMESPACE=$(prefix="apicast" && printf "%s-%s\n" "$prefix" $(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 5))
DEPLOYMENT_ENVIRONMENT="production"
ADMIN_PORTAL_PROVIDER_KEY=""

# --- Argument Parsing ---
while getopts "k:u:n:e:" opt; do
  case $opt in
    k) ADMIN_PORTAL_PROVIDER_KEY="$OPTARG" ;;
    u) PUBLIC_BASE_URL="$OPTARG" ;;
    n) NAMESPACE="$OPTARG" ;;
    e) DEPLOYMENT_ENVIRONMENT="$OPTARG" ;;
    *) echo "Usage: $0 -k <ADMIN_PORTAL_PROVIDER_KEY> -u <PUBLIC_BASE_URL> [-n <NAMESPACE>] [-e <production|staging>]"; exit 1 ;;
  esac
done

# --- Validation ---
if [ -z "$ADMIN_PORTAL_PROVIDER_KEY" ]; then
    echo "Error: -u <ADMIN_PORTAL_PROVIDER_KEY> is required."
    exit 1
fi

if [ -z "$PUBLIC_BASE_URL" ]; then
    echo "Error: -k <PUBLIC_BASE_URL> is required."
    exit 1
fi

if [[ "$DEPLOYMENT_ENVIRONMENT" != "production" && "$DEPLOYMENT_ENVIRONMENT" != "staging" ]]; then
    echo "Error: -e <ENVIRONMENT> must be 'production' or 'staging'."
    exit 1
fi

# --- Variables ---
APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
ADMIN_PORTAL_SECRET=admin-portal-creds
ADMIN_PORTAL_DOMAIN="3scale-admin.${APPS_DOMAIN}"
ADMIN_PORTAL_URL="https://${ADMIN_PORTAL_PROVIDER_KEY}@${ADMIN_PORTAL_DOMAIN}/"

echo "--- 1. Preparing Namespace ---"
echo " Using Namespace: ${NAMESPACE}"
echo " Using Environment: ${DEPLOYMENT_ENVIRONMENT}"

if oc get project "$NAMESPACE" &>/dev/null; then
    echo " Using existing namespace: ${NAMESPACE}"
    oc project "$NAMESPACE"
else
    echo " Creating namespace: ${NAMESPACE}"
    oc create namespace "$NAMESPACE"
    oc project "$NAMESPACE"
fi

echo "--- 2. Installing APICast Operator ---"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: apicast
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
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
oc delete secret "${ADMIN_PORTAL_SECRET}" -n "$NAMESPACE" --ignore-not-found
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
  deploymentEnvironment: $DEPLOYMENT_ENVIRONMENT
  logLevel: debug
  pathRoutingEnabled: true
EOF

echo "--- 5. Creating Public Base URL Route ---"
oc create route edge public-base-url --service=apicast-apicast --port=proxy --insecure-policy='Redirect' --hostname=${PUBLIC_BASE_URL}

echo "--------------------------------------------------"
echo "Deployment started in namespace: $NAMESPACE"
echo "Targeting 3scale environment: $DEPLOYMENT_ENVIRONMENT"
echo "--------------------------------------------------"
