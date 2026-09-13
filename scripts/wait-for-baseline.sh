#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

region="$(aws_region)"
asg_name="$(tf_output asg_name)"
desired="$(aws autoscaling describe-auto-scaling-groups \
  --region "${region}" \
  --auto-scaling-group-names "${asg_name}" \
  --query 'AutoScalingGroups[0].DesiredCapacity' \
  --output text)"

echo "Waiting for ${desired} InService instances in ${asg_name}..."
for attempt in $(seq 1 60); do
  in_service="$(aws autoscaling describe-auto-scaling-groups \
    --region "${region}" \
    --auto-scaling-group-names "${asg_name}" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService` && HealthStatus==`Healthy`])' \
    --output text)"
  if [[ "${in_service}" == "${desired}" ]]; then
    instance_ids="$(aws autoscaling describe-auto-scaling-groups \
      --region "${region}" \
      --auto-scaling-group-names "${asg_name}" \
      --query 'AutoScalingGroups[0].Instances[].InstanceId' \
      --output text)"
    aws ec2 wait instance-status-ok --region "${region}" --instance-ids ${instance_ids}
    echo "Baseline is healthy: ${instance_ids}"
    exit 0
  fi
  if (( attempt % 6 == 0 )); then
    echo "Still waiting (${in_service}/${desired} healthy and InService)..."
  fi
  sleep 10
done

echo "Timed out waiting for the baseline ASG" >&2
exit 1
