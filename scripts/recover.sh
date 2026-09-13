#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <previous-lab-ami-id>" >&2
  exit 2
fi

recovery_ami="$1"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

region="$(aws_region)"
project="$(tf_output project_name)"
parameter_name="$(tf_output ami_parameter_name)"
asg_name="$(tf_output asg_name)"
account_id="$(aws sts get-caller-identity --query Account --output text)"

image_count="$(aws ec2 describe-images \
  --region "${region}" \
  --owners "${account_id}" \
  --image-ids "${recovery_ami}" \
  --filters "Name=state,Values=available" "Name=tag:Project,Values=${project}" \
  --query 'length(Images)' \
  --output text)"
if [[ "${image_count}" != "1" ]]; then
  echo "Refusing recovery: ${recovery_ami} is not one available AMI owned by this account and tagged Project=${project}" >&2
  exit 1
fi

active_count="$(aws autoscaling describe-instance-refreshes \
  --region "${region}" \
  --auto-scaling-group-name "${asg_name}" \
  --query 'length(InstanceRefreshes[?Status==`Pending` || Status==`InProgress` || Status==`Baking` || Status==`RollbackInProgress` || Status==`Cancelling`])' \
  --output text)"
if [[ "${active_count}" != "0" ]]; then
  echo "Refusing recovery while an instance refresh is active" >&2
  exit 1
fi

aws ssm put-parameter \
  --region "${region}" \
  --name "${parameter_name}" \
  --type String \
  --data-type aws:ec2:image \
  --value "${recovery_ami}" \
  --overwrite >/dev/null
echo "Restored ${parameter_name} to ${recovery_ami}; the Update event should trigger a refresh."
