# Delete all projects that start with '3scale-'
oc get project -o name | grep '3scale-' | cut -d '/' -f 2 | xargs oc delete --wait=false project
