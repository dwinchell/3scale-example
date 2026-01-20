# Delete all projects that start with 'apicast-'
oc get project -o name | grep 'apicast-' | cut -d '/' -f 2 | xargs oc delete --wait=false project

