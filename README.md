# 3Scale Example

Example of how to deploy 3Scale with Self-Managed APICast instances on OpenShift.

## Usage

### Installing 3Scale

./install-3scale.sh

### Getting the Provider Key

1. Get the URL for the admin console by looking at the route. It should look similar to https://3scale-admin.apps.example.org/.
2. Get the credentials from the secret.
3. Login to the admin console.
3. From the top navigation dropdown, select Accont Settings
5. Copy the Provider API Key. Do not include any trailing spaces.


### Installing APICast

```
./install-apicast.sh -k <PROVIDER_KEY> -n apicast-staging -e staging
./install-apicast.sh -k <PROVIDER_KEY> -n apicast-production -e production
```

