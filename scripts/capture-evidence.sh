#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

region="$(aws_region)"
parameter_name="$(tf_output ami_parameter_name)"
asg_name="$(tf_output asg_name)"
pipeline_arn="$(tf_output image_pipeline_arn)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
evidence_dir="${REPO_DIR}/evidence/${timestamp}"
mkdir -p "${evidence_dir}"

terraform -chdir="${REPO_DIR}" output -json >"${evidence_dir}/terraform-outputs.json"
aws ssm get-parameter \
  --region "${region}" \
  --name "${parameter_name}" >"${evidence_dir}/parameter.json"
aws imagebuilder list-image-pipeline-images \
  --region "${region}" \
  --image-pipeline-arn "${pipeline_arn}" >"${evidence_dir}/pipeline-images.json"
aws autoscaling describe-instance-refreshes \
  --region "${region}" \
  --auto-scaling-group-name "${asg_name}" >"${evidence_dir}/instance-refreshes.json"
aws autoscaling describe-auto-scaling-groups \
  --region "${region}" \
  --auto-scaling-group-names "${asg_name}" >"${evidence_dir}/asg.json"

instance_ids="$(aws autoscaling describe-auto-scaling-groups \
  --region "${region}" \
  --auto-scaling-group-names "${asg_name}" \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' \
  --output text)"
if [[ -n "${instance_ids}" && "${instance_ids}" != "None" ]]; then
  aws ec2 describe-instances \
    --region "${region}" \
    --instance-ids ${instance_ids} >"${evidence_dir}/instances.json"
fi

echo "Evidence saved to ${evidence_dir}"
