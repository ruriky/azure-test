#!/bin/sh
# Auto DevOps variables and functions
[[ "$TRACE" ]] && set -x

export DOCKER_IMAGE_TAG_BASE=${CI_REGISTRY_IMAGE}/${DOCKER_IMAGE_NAME}
export DOCKER_IMAGE_TAG=${DOCKER_IMAGE_TAG_BASE}:${CI_COMMIT_SHA}

function registry_login() {
  if [[ -n "$CI_REGISTRY_USER" ]]; then
    echo "Logging to GitLab Container Registry with CI credentials..."
    docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    echo ""
  fi
}

function fetch_submodules() {
  git submodule sync && git submodule update --init
}

function deploy_name() {
  name="$CI_ENVIRONMENT_SLUG"
  track="${1-stable}"

  if [[ "$track" != "stable" ]]; then
    name="$name-$track"
  fi

  echo $name
}

function application_secret_name() {
  track="${1-stable}"
  name=$(deploy_name "$track")

  echo "${name}-secret"
}

function test() {
  fetch_submodules
  registry_login

  docker pull $DOCKER_IMAGE_TAG
  export DOCKER_HOST='tcp://localhost:2375'
  export DOCKER_APP_IMAGE=$DOCKER_IMAGE_TAG
  export DOCKER_APP_COMMAND="make test-setup && make test"
  make ci-command
}


# Extracts variables prefixed with K8S_SECRET_
# and creates a Kubernetes secret.
#
# e.g. If we have the following environment variables:
#   K8S_SECRET_A=value1
#   K8S_SECRET_B=multi\ word\ value
#
# Then we will create a secret with the following key-value pairs:
#   data:
#     A: dmFsdWUxCg==
#     B: bXVsdGkgd29yZCB2YWx1ZQo=
function create_application_secret() {
  track="${1-stable}"
  export APPLICATION_SECRET_NAME=$(application_secret_name "$track")

  bash -c '
    function k8s_prefixed_variables() {
      env | sed -n "s/^K8S_SECRET_\(.*\)$/\1/p"
    }

    kubectl create secret \
      -n "$KUBE_NAMESPACE" generic "$APPLICATION_SECRET_NAME" \
      --from-env-file <(k8s_prefixed_variables) -o yaml --dry-run |
      kubectl replace -n "$KUBE_NAMESPACE" --force -f -
  '
}

function kube_auth() {
  cluster="${1-production}"

  if [ "$cluster" = "qa" ]; then
    # TODO: TIX TYPO
    k8s_cluster="$K8S_QA_CLUSTER_NAME"
    k8s_token="$K8S_QA_TOKEN"
    k8s_api_url="$K8S_QA_API_URL"
  elif [ "$cluster" = "production" ]; then
    k8s_cluster="$K8S_CLUSTER_NAME"
    k8s_token="$K8S_TOKEN"
    k8s_api_url="$K8S_API_URL"
  fi

  echo "$K8S_QA_CERTIFICATE" > ca.crt
  kubectl config set-cluster "$k8s_cluster" --server "$k8s_api_url" --certificate-authority=ca.crt
  kubectl config set-credentials "$k8s_cluster" --token="$k8s_token"
  kubectl config set-context "$k8s_cluster" --user="$k8s_cluster" --cluster="$k8s_cluster" --namespace="$KUBE_NAMESPACE"
  kubectl config use-context "$k8s_cluster"
}

function ensure_namespace() {
  kubectl describe namespace "$KUBE_NAMESPACE" || (kubectl create namespace "$KUBE_NAMESPACE" && kubectl label namespace $KUBE_NAMESPACE app=kubed)
  kubectl label namespace $KUBE_NAMESPACE app=kubed --overwrite
}

# Make sure that Helm repos are set up
function setup_helm() {
  echo "Setting up Helm"
  helm init --client-only
  helm repo update
}

function set_database_url() {
  track="${1-stable}"

  # Make the track uppercase (Note: only A-Z support)
  uppercase_track=$(echo ${track} | tr a-z A-Z)

  # Create environment variable name
  database_var=K8S_${uppercase_track}_DATABASE_URL

  # Set database url
  eval "export DATABASE_URL=\${$database_var}"
}

function initialize_database() {
  track="${1-stable}"
  name=$(deploy_name "$track")

  if [[ -z "$MYSQL_ENABLED" ]] && [[ "$POSTGRES_ENABLED" -eq 1 ]]; then
    initialize_postgres "$track"
  elif [[ "$MYSQL_ENABLED" -eq 1 ]]; then
    initialize_mysql "$track"
  fi
}

# Deploys a database for the application
function initialize_postgres() {
  track="${1-stable}"
  name=$(deploy_name "$track")

  # Database
  export DATABASE_HOST=${name}-postgres
  auto_database_url=postgres://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:5432/${DATABASE_DB}
  export DATABASE_URL=${DATABASE_URL-$auto_database_url}

  echo "Settings up Postgresql database"
  helm fetch stable/postgresql --version 3.10.1 --untar --untardir /tmp/devops/ci-configuration/database/helm
  mkdir -p /tmp/devops/ci-configuration/database/manifests
  helm template /tmp/devops/ci-configuration/database/helm/postgresql \
    --name "$name" \
    --namespace "$KUBE_NAMESPACE" \
    --set image.tag="$POSTGRES_VERSION_TAG" \
    --set postgresqlUsername="$DATABASE_USER" \
    --set postgresqlPassword="$DATABASE_PASSWORD" \
    --set postgresqlDatabase="$DATABASE_DB" \
    --set nameOverride="postgres" \
    --output-dir /tmp/devops/ci-configuration/database/manifests

  # --force is a destructive and disruptive action and will cause the service to be recreated and
  #         and will cause downtime. We don't mind in this case we do _want_ to recreate everything.
  kubectl replace --recursive -f /tmp/devops/ci-configuration/database/manifests/postgresql --force
  sleep 5
  kubectl wait pod --for=condition=ready --timeout=600s -l app=postgres,release=${name}
}

# Deploys a MySQL database for the application
function initialize_mysql() {
  track="${1-stable}"
  name=$(deploy_name "$track")

  # Database
  export DATABASE_HOST=${name}-mysql
  auto_database_url=mysql://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:3306/${DATABASE_DB}
  export DATABASE_URL=${DATABASE_URL-$auto_database_url}

  echo "Settings up MySQL database"
  helm fetch stable/mysql --untar --untardir /tmp/devops/ci-configuration/database/helm
  mkdir -p /tmp/devops/ci-configuration/database/manifests
  helm template /tmp/devops/ci-configuration/database/helm/mysql \
    --name "$name" \
    --namespace "$KUBE_NAMESPACE" \
    --set imageTag="$MYSQL_VERSION_TAG" \
    --set mysqlUser="$DATABASE_USER" \
    --set mysqlPassword="$DATABASE_PASSWORD" \
    --set mysqlRootPassword="$DATABASE_PASSWORD" \
    --set mysqlDatabase="$DATABASE_DB" \
    --output-dir /tmp/devops/ci-configuration/database/manifests

  # --force is a destructive and disruptive action and will cause the service to be recreated and
  #         and will cause downtime. We don't mind in this case we do _want_ to recreate everything.
  kubectl replace --recursive -f /tmp/devops/ci-configuration/database/manifests/mysql --force
  sleep 5
  kubectl wait pod --for=condition=ready --timeout=600s -l app=${name}-mysql,release=${name}
}

function deploy() {
  track="${1-stable}"
  name=$(deploy_name "$track")

  # Copy default helm chart if one isn't present in the repo
  if [[ ! -d "./helm" ]]; then
    mkdir ./helm
    cp -r /tmp/devops/ci-configuration/helm/* ./helm/.
  fi

  service_port=${SERVICE_PORT-8000}

  set_database_url "$track"
  initialize_database "$track"
  mkdir /tmp/devops/manifests
  helm template ./helm \
    --name "$name" \
    --set namespace="$KUBE_NAMESPACE" \
    --set image="$DOCKER_IMAGE_TAG" \
    --set gitlab.app="$CI_PROJECT_PATH_SLUG" \
    --set gitlab.env="$CI_ENVIRONMENT_SLUG" \
    --set releaseOverride="$CI_ENVIRONMENT_SLUG" \
    --set application.track="$track" \
    --set application.database_url="$DATABASE_URL" \
    --set application.database_host="$DATABASE_HOST" \
    --set application.secretName="$APPLICATION_SECRET_NAME" \
    --set application.initializeCommand="$DB_INITIALIZE" \
    --set application.migrateCommand="$DB_MIGRATE" \
    --set service.url="$CI_ENVIRONMENT_URL" \
    --set service.targetPort=${SERVICE_PORT-8000} \
    --output-dir /tmp/devops/manifests

  # [Re-] Running jobs by first removing them and then applying them again
  if [[ -n "$DB_INITIALIZE" ]]; then
    echo "Applying initialization command..."
    kubectl delete --ignore-not-found jobs/${name}-initialize
    kubectl apply -f ./manifests/anders-deploy-app/templates/00-init-job.yaml
    kubectl wait --for=condition=complete --timeout=600s jobs/${name}-initialize

    rm /tmp/devops/manifests/anders-deploy-app/templates/00-init-job.yaml
  fi

  if [[ -n "$DB_MIGRATE" ]]; then
    echo "Applying migration command..."
    kubectl delete --ignore-not-found jobs/${name}-migrate
    kubectl apply -f /tmp/devops/manifests/anders-deploy-app/templates/01-migrate-job.yaml
    kubectl wait --for=condition=complete --timeout=600s jobs/${name}-migrate

    rm /tmp/devops/manifests/anders-deploy-app/templates/01-migrate-job.yaml
  fi

  echo "Deploying application"
  echo "Namespace: ${KUBE_NAMESPACE}"
  echo "Track: ${track}"
  echo "Image: ${DOCKER_IMAGE_TAG}"
  kubectl apply --recursive -f /tmp/devops/manifests/anders-deploy-app/templates

  echo "Waiting for deployment to be available"
  kubectl wait --for=condition=available --timeout=600s deployments/${name}
}

function build() {
  fetch_submodules
  registry_login

  # Pull, build, tag, and push every named stage from the Dockerfile for effective caching
  set +e
  grep -i "^FROM .* as .*$" ${DOCKER_BUILD_SOURCE} | while read -r match ; do
    stage=$(echo "$match" | sed -E 's/^FROM .* AS (.*)$/\1/I')
    if [[ ! -z "$stage" ]] ; then
      echo "Building stage: $stage"
      build_stage $stage
    fi
  done
  set -e

  # Finally build the entire image
  echo "Building full image"
  build_stage
}

function build_stage() {
  if [[ ! -z "$1" ]] ; then
    tag_suffix="-$1"
  else
    tag_suffix=""
  fi

  commit_ref=$(echo "${CI_COMMIT_REF_NAME}" | tr _/ -)

  if ! docker pull ${DOCKER_IMAGE_TAG_BASE}:master${tag_suffix} > /dev/null; then
    echo "Pulling latest master image for the project failed, running without cache"
  else
    echo "Downloaded docker build cache from latest master image"
  fi
  if ! docker pull ${DOCKER_IMAGE_TAG_BASE}:${commit_ref}${tag_suffix} > /dev/null; then
    echo "Pulling branch specific docker cache failed, building without"
  else
    echo "Downloaded docker build cache from latest branch specific image"
  fi

  export CACHE_FROM="$(cat /tmp/devops/build-cache 2>/dev/null)"
  export CACHE_FROM="${CACHE_FROM} --cache-from ${DOCKER_IMAGE_TAG_BASE}:master${tag_suffix}"
  export CACHE_FROM="${CACHE_FROM} --cache-from ${DOCKER_IMAGE_TAG}${tag_suffix}"
  export CACHE_FROM="${CACHE_FROM} --cache-from ${DOCKER_IMAGE_TAG_BASE}:${commit_ref}${tag_suffix}"
  echo $CACHE_FROM > /tmp/devops/build-cache

  build_cmd="docker build"
  build_cmd="${build_cmd} ${CACHE_FROM}"
  build_cmd="${build_cmd} -t ${DOCKER_IMAGE_TAG}${tag_suffix}"
  build_cmd="${build_cmd} -t ${DOCKER_IMAGE_TAG_BASE}:${commit_ref}${tag_suffix}"
  build_cmd="${build_cmd} -f ${DOCKER_BUILD_SOURCE} ."

  if [[ ! -z "$tag_suffix" ]] ; then
    build_cmd="${build_cmd} --target $1"
  fi

  echo $build_cmd
  eval $build_cmd

  echo "Pushing to GitLab Container Registry..."
  docker push ${DOCKER_IMAGE_TAG}${tag_suffix}
  docker push ${DOCKER_IMAGE_TAG_BASE}:${commit_ref}${tag_suffix}
  echo ""
}

function delete() {
  track="${1-stable}"
  name=$(deploy_name "$track")

  # kubectl delete \
  #   pods,services,jobs,deployments,statefulsets,configmap,serviceaccount,rolebinding,role \
  #   -l release="$name" \
  #   -n "$KUBE_NAMESPACE" \
  #   --include-uninitialized
  # TODO: Split to multiple lines. For some reason the solution above breaks if doing so
  kubectl delete pods,services,jobs,deployments,statefulsets,configmap,serviceaccount,rolebinding,role -l release="$name" -n "$KUBE_NAMESPACE" --include-uninitialized


  secret_name=$(application_secret_name "$track")
  kubectl delete secret --ignore-not-found -n "$KUBE_NAMESPACE" "$secret_name"
}
