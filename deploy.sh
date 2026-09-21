#!/usr/bin/env bash
# Builds & pushes the ECS app image to ECR, then runs terraform apply with a
# unique image tag so ECS actually picks up the new image (a fresh tag forces
# the task definition to change, which triggers a new ECS deployment).
#
# Usage: ./deploy.sh
# Run this any time you change src/ecs/app.py (or other app code) and need
# to ship a new image.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$REPO_ROOT/src/infra"
ECS_DIR="$REPO_ROOT/src/ecs"
VAR_FILE="envs/dev/dev.tfvars"

cd "$INFRA_DIR"

echo "==> Ensuring base infra exists (ECR repo, cluster, RDS, API GW)..."
# Skip re-init if providers are already cached locally, so a flaky/offline
# registry.terraform.io doesn't block a deploy that doesn't need it.
if [ ! -d ".terraform/providers" ]; then
  terraform init -input=false >/dev/null
fi
terraform apply -input=false -auto-approve -var-file="$VAR_FILE"

ECR_URL="$(terraform output -raw ecr_repository_url)"
AWS_REGION="$(terraform output -raw invoke_url 2>/dev/null | sed -E 's#.*execute-api\.([a-z0-9-]+)\.amazonaws.*#\1#' || true)"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Unique tag per build so Terraform sees a real change and redeploys ECS.
IMAGE_TAG="$(date +%Y%m%d%H%M%S)-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"

echo "==> Logging in to ECR ($ECR_URL)..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_URL"

echo "==> Building image (linux/amd64, required by Fargate)..."
docker build --platform linux/amd64 -t "$ECR_URL:$IMAGE_TAG" -t "$ECR_URL:latest" "$ECS_DIR"

echo "==> Pushing $ECR_URL:$IMAGE_TAG and :latest..."
docker push "$ECR_URL:$IMAGE_TAG"
docker push "$ECR_URL:latest"

echo "==> Applying terraform with image_tag=$IMAGE_TAG (triggers ECS redeploy)..."
terraform apply -input=false -auto-approve -var-file="$VAR_FILE" -var="image_tag=$IMAGE_TAG"

echo "==> Done. Invoke URL:"
terraform output courses_count_invoke_url
