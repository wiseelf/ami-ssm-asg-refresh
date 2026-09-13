#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_command terraform
require_command aws

execute=false
if [[ "${1:-}" == "--execute" ]]; then
  execute=true
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--execute]" >&2
  exit 2
fi

region="${AWS_REGION:-}"
project="${PROJECT_NAME:-}"
if [[ -z "${region}" ]]; then
  region="$(tf_output aws_region 2>/dev/null || true)"
fi
if [[ -z "${project}" ]]; then
  project="$(tf_output project_name 2>/dev/null || true)"
fi
if [[ -z "${region}" || -z "${project}" ]]; then
  echo "Set AWS_REGION and PROJECT_NAME when Terraform outputs are no longer available." >&2
  exit 2
fi
account_id="$(aws sts get-caller-identity --query Account --output text)"
image_ids="$(aws ec2 describe-images \
  --region "${region}" \
  --owners "${account_id}" \
  --filters "Name=tag:Project,Values=${project}" \
  --query 'Images[].ImageId' \
  --output text)"

if [[ -z "${image_ids}" || "${image_ids}" == "None" ]]; then
  echo "No account-owned AMIs tagged Project=${project}."
  exit 0
fi

aws ec2 describe-images \
  --region "${region}" \
  --image-ids ${image_ids} \
  --query 'Images[].{ImageId:ImageId,Name:Name,State:State,Snapshots:BlockDeviceMappings[].Ebs.SnapshotId}'

if [[ "${execute}" != "true" ]]; then
  echo "Inventory only. After Terraform destroy, set AWS_REGION=${region} PROJECT_NAME=${project} and rerun with --execute."
  exit 0
fi

in_use_count="$(aws ec2 describe-instances \
  --region "${region}" \
  --filters "Name=image-id,Values=$(tr ' ' ',' <<<"${image_ids}")" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'length(Reservations[].Instances[])' \
  --output text)"
if [[ "${in_use_count}" != "0" ]]; then
  echo "Refusing cleanup: ${in_use_count} non-terminated instance(s) still use a lab AMI" >&2
  exit 1
fi

for image_id in ${image_ids}; do
  snapshot_ids="$(aws ec2 describe-images \
    --region "${region}" \
    --image-ids "${image_id}" \
    --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' \
    --output text)"
  echo "Deregistering ${image_id}"
  aws ec2 deregister-image --region "${region}" --image-id "${image_id}"
  for snapshot_id in ${snapshot_ids}; do
    echo "Deleting ${snapshot_id}"
    aws ec2 delete-snapshot --region "${region}" --snapshot-id "${snapshot_id}"
  done
done
