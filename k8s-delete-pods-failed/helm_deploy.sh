#!/bin/bash
#GITLAB_PVT_TOKEN
echo $ROUTE_53_TEMPLATE > application-url-version.json
BRANCH_JOB=$(curl -X GET https://gitlab.com/api/v4/projects/$CI_PROJECT_ID/jobs/$CI_JOB_ID -H "Private-Token: $GITLAB_PVT_TOKEN" | jq .ref)
MERGE_REQUEST=$(curl -X GET https://gitlab.com/api/v4/merge_requests -H "Private-Token: $GITLAB_PVT_TOKEN" | jq -c ".[] | select( .source_branch == $BRANCH_JOB)")
MILESTONE_NAME=$(echo $MERGE_REQUEST | jq .milestone.title | sed -e "s/\"//g")
BRANCH_JOB=$(echo $BRANCH_JOB | sed -e "s/\"//g")

BRANCH_JOB=$(echo $BRANCH_JOB | sed -e "s/\"//g" | cut -b 1-15)
if [ "${BRANCH_JOB: -1}" == '-' ]; then # remove last caracter if "-"
  BRANCH_JOB="${BRANCH_JOB::-1}"
fi

if echo $BRANCH_JOB | grep -e '^v[0-9]\+\.[0-9]\+\.[0-9]\+' &>/dev/null; then  # eh uma tag?
  if git branch -r | grep -e 'origin/main$' &>/dev/null; then
    BRANCH_JOB=${SUBENVIRONMENT:-main}
  else
    BRANCH_JOB=${SUBENVIRONMENT:-master}
  fi
fi

if [[ $MILESTONE_NAME == null ]]; then
  MILESTONE_NAME=""
else
  MILESTONE_NAME="$MILESTONE_NAME-"
fi
MERGE_REQUEST_ID=$(echo $MERGE_REQUEST | jq .id | sed -e "s/\"//g")
URL_VERSION="$CI_PROJECT_NAME-$BRANCH_JOB.$DOMAIN"
VERSION_URL_EXISTS=$(aws route53 list-resource-record-sets --hosted-zone-id $AWS_HOSTED_ZONE_ID | jq -c ".[]" | jq -c ".[] | select( .Name == \"$URL_VERSION.\")")
sed -i "s,<URL_VERSION>,$URL_VERSION,g; s,<ISTIO_ADDRESS>,$ISTIO_ADDRESS,g;" application-url-version.json
if [ -n "$VERSION_URL_EXISTS" ]; then
  echo "environment already registered ;)"
else
  aws route53 change-resource-record-sets --hosted-zone-id $AWS_HOSTED_ZONE_ID --change-batch file://application-url-version.json
fi
DESCRIBED_VERSION=$(cat ci_cd/DESCRIBED_VERSION.txt 2>/dev/null || git describe --tags 2>/dev/null || echo "v0.0.0-$(git rev-list HEAD --count || echo 0)-g$(git rev-parse --short HEAD || echo 0000000)")

## Build values with environment variables
cp k8s-delete-pods-failed/values.yaml temp_values.yaml

for env_var in $(compgen -v | grep -E [[:alnum:]_]\{4,\}); do
  ESCAPED_ENVIRONMENT_VARIABLE=$(echo "${!env_var}" | sed 's,\,,\\\,,g')
  sed -i -r "s,\{\{\s?$env_var\s?\}\},$ESCAPED_ENVIRONMENT_VARIABLE,g" temp_values.yaml # replace variables at values.yaml
done

sed -i -r "s,\{\{\s?\w+\s?\}\},,g" temp_values.yaml # clear unused variable placeholders

if [ -z "$RELEASE_NAME" ]; then # not exists
  if [ -z "$SUBENVIRONMENT" ]; then
    RELEASE_NAME="${K8S_SERVICE_NAME:-del-failed-conjob}-$BRANCH_JOB"
  else
    RELEASE_NAME="${K8S_SERVICE_NAME:-del-failed-conjob}-$SUBENVIRONMENT-$NAMESPACE"
  fi
fi

## set deployment environment
dep_environment='dev'
case "$CI_ENVIRONMENT_NAME" in
production)
  dep_environment='prod'
  ;;
staging-k8s)
  dep_environment='dev'
  ;;
homolog-k8s)
  # dep_environment='hml'
  dep_environment='dev'
  ;;
esac


TARGET_PORT=$(cat temp_values.yaml | grep targetPort | cut -d ":" -f 2 | tr -d ' ')
PORT=$(cat temp_values.yaml | grep port | head -n 1 | tr -d ' ' | cut -d ':' -f 2)
echo "
Variables to deployment:
RELEASE_NAME=$RELEASE_NAME
CHART=$APP_BACKEND_CHART
CHART_VERSION=$CHART_VERSION
BRANCH_JOB=$BRANCH_JOB
CI_PROJECT_NAME=$CI_PROJECT_NAME
DESCRIBED_VERSION=$DESCRIBED_VERSION
CI_COMMIT_SHORT_SHA=$CI_COMMIT_SHORT_SHA
CHART_VERSION=$CHART_VERSION
DOMAIN=$DOMAIN
NAMESPACE=$NAMESPACE
PORT=$PORT
TARGET_PORT=$TARGET_PORT
dep_environment=$dep_environment
CERT_MANAGER_ACCESS_KEY_ID=$CERT_MANAGER_ACCESS_KEY_ID
"
set -x
helm repo update
helm upgrade --wait --cleanup-on-fail --install --debug "$RELEASE_NAME" --values temp_values.yaml "$APP_BACKEND_CHART" --version "$CHART_VERSION" --set app.mergeRequest="$BRANCH_JOB" --set app.name="$CI_PROJECT_NAME" --set app.commit="$DESCRIBED_VERSION" --set deployment.environment="$dep_environment" --set providersConfig.route53.AwsAccessKeyId="$CERT_MANAGER_ACCESS_KEY_ID" --set app.subenvironment="$SUBENVIRONMENT" --namespace $NAMESPACE
set +x

if [ -f ./gcr-access-token.txt ] && [ "$NAMESPACE" == "homolog" ]; then
    curl "https://gcr.io/v2/truckpad-176922/$CI_PROJECT_NAME/manifests/$DESCRIBED_VERSION" \
        -H 'accept: application/vnd.docker.distribution.manifest.v2+json' \
        --user "_token:$(cat ./gcr-access-token.txt)" \
        > /tmp/image-manifest.json && \
    curl -XPUT "https://gcr.io/v2/truckpad-176922/$CI_PROJECT_NAME/manifests/${SUBENVIRONMENT}-homolog" \
        -H 'Content-Type: application/vnd.docker.distribution.manifest.v2+json' \
        --user "_token:$(cat ./gcr-access-token.txt)" \
        -d "$(cat /tmp/image-manifest.json)" && \
    echo "Tag '${SUBENVIRONMENT}-homolog' added to gcr.io/truckpad-176922/$CI_PROJECT_NAME:$DESCRIBED_VERSION"
fi
