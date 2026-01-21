# 3Scale ARO Deployment Example
This project provides automated scripts to deploy Red Hat 3Scale and Self-Managed APIcast instances on Azure Red Hat OpenShift (ARO). It is optimized for ARO storage requirements, specifically handling the differences between block storage for databases and shared file storage for 3Scale assets.

## Prerequisites

1. An authenticated oc CLI session to an Azure Red Hat OpenShift cluster.
2. Cluster-admin or sufficient project-admin permissions.

## 1. Installing 3Scale
The install-3scale.sh script deploys the 3Scale operator, sets up manual PostgreSQL and Redis instances using optimized storage, and initiates the APIManager.

The storage classes below are installed by default if you are using Azure Red Hat OpenShift (ARO).

```
# Basic installation (uses random namespace)
./install-3scale.sh

# Recommended: Specify namespace and storage classes
# -d managed-csi (Block storage for DB performance)
# -s azurefile-csi (Shared storage for RWX support)
./install-3scale.sh -n 3scale-core -d managed-csi -s azurefile-csi
```

#### Retrieving Credentials
Upon completion, the script will automatically output your credentials and the Provider API Key. You will need this key for the APIcast installation.

## 2. Installing Self-Managed APIcast
Once 3Scale is ready, deploy your APIcast gateways. These gateways are configured for Path-Based Routing, allowing multiple services to share a single domain.

### Usage

```
./install-apicast.sh -k <PROVIDER_KEY> -n <NAMESPACE> [-e <production|staging>]
```

### Example

```
# Deploy Staging Gateway
./install-apicast.sh -k 14ac5eb4... -n apicast-staging -e staging

# Deploy Production Gateway
./install-apicast.sh -k 14ac5eb4... -n apicast-production -e production
```

## 3. Configuring Path-Based Routing
Because pathRoutingEnabled is set to true in these gateways, you must configure your 3Scale services accordingly:

Public Base URL: In the 3Scale Admin Portal, set the Public Base URL to your common domain (e.g., https://api.apps.cluster.com for production and https://api.apps.cluster.com for staging).

Promote: Always click Promote to Production after making changes so the self-managed gateways can pull the new production.json configuration.

## Troubleshooting Storage
If your database pods are in CrashLoopBackOff, ensure you are using a block storage class (managed-csi) for the -d flag. Azure File (azurefile-csi) does not support the POSIX permissions required by PostgreSQL.
