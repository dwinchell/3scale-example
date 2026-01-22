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
./install-3scale.sh -n 3scale -d managed-csi -s azurefile-csi
```

#### Retrieving Credentials
Once 3scale is ready and you have retrieved your Provider Key, deploy your APIcast gateways. These gateways are configured for Path-Based Routing, allowing multiple services to share a single domain.

1. **Log in:** Use the URL and credentials from the script output to log into the Admin Portal.
2. **Navigate:** Dismiss the "Getting Started" tour, select the Dashboard dropdown in the top navigation, and click Account Settings.
3. **Copy Key:** Copy the Provider Key (large text). Ensure you do not include trailing spaces.
4. **Proceed:** Use this key as the -k argument for the APIcast installation.

## 2. Installing Self-Managed APIcast

Once 3Scale is ready, deploy your APIcast gateways. These gateways are configured for Path-Based Routing, allowing multiple services to share a single domain.

### Usage
```
./install-apicast.sh -k <PROVIDER_KEY> -u <PUBLIC_BASE_URL> -n <NAMESPACE> [-e <production|staging>]
```

### Examples

```
# Deploy Production Gateway
./install-apicast.sh -k 14ac5eb4... -u api-staging.apps.edm3g8k3.eastus.aroapp.io -n apicast-staging -e staging
./install-apicast.sh -k 14ac5eb4... -u api.apps.edm3g8k3.eastus.aroapp.io -n apicast-production -e production
```

## 3. Configuring Path-Based Routing
Because pathRoutingEnabled is set to true, you must configure your 3scale services in the Admin Portal:

Public Base URL: Set this to the hostname provided in the -u flag during APIcast installation.

Promote: Always click Promote to Staging/Production after changes so the gateways can fetch the updated json configuration.

## Troubleshooting

### Storage Issues

If database pods are in CrashLoopBackOff, verify you used managed-csi for the -d flag. Azure File (azurefile-csi) does not support the POSIX permissions (chmod/chown) required by PostgreSQL.

