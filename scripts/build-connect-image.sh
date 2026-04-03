#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
CP_VERSION="${CP_VERSION:-7.9.0}"
DEBEZIUM_VERSION="${DEBEZIUM_VERSION:-3.1.2.Final}"
JDBC_SINK_VERSION="${JDBC_SINK_VERSION:-10.8.0}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -f terraform.tfvars ] && grep -q project_name terraform.tfvars; then
  PROJECT_NAME=$(grep project_name terraform.tfvars | awk -F'"' '{print $2}')
else
  PROJECT_NAME="cdc-on-cpc"
fi
ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}/cp-server-connect-custom"
IMAGE_TAG="${CP_VERSION}-dbz${DEBEZIUM_VERSION}"
printf ">>> Building %s:%s\n" "${ECR_REPO}" "${IMAGE_TAG}"
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "${BUILD_DIR}"' EXIT
printf ">>> Downloading Debezium %s ...\n" "${DEBEZIUM_VERSION}"
curl -fSL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-sqlserver/${DEBEZIUM_VERSION}/debezium-connector-sqlserver-${DEBEZIUM_VERSION}-plugin.tar.gz" -o "${BUILD_DIR}/debezium.tar.gz"
mkdir -p "${BUILD_DIR}/debezium-connector-sqlserver"
tar -xzf "${BUILD_DIR}/debezium.tar.gz" -C "${BUILD_DIR}/debezium-connector-sqlserver" --strip-components=1
rm -f "${BUILD_DIR}/debezium.tar.gz"
cat > "${BUILD_DIR}/Dockerfile" <<DFILE
FROM confluentinc/cp-server-connect:${CP_VERSION}
USER root
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:${JDBC_SINK_VERSION}
COPY debezium-connector-sqlserver/ /usr/share/java/debezium-connector-sqlserver/
USER 1001
DFILE
docker build --platform linux/amd64 --no-cache -t "${ECR_REPO}:${IMAGE_TAG}" "${BUILD_DIR}"
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
docker push "${ECR_REPO}:${IMAGE_TAG}"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"
printf ">>> Done: %s:%s\n" "${ECR_REPO}" "${IMAGE_TAG}"
