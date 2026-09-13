#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <expected-release-id>" >&2
  exit 2
fi

expected_release="$1"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

region="$(aws_region)"
parameter_name="$(tf_output ami_parameter_name)"
asg_name="$(tf_output asg_name)"
target_ami="$(aws ssm get-parameter --region "${region}" --name "${parameter_name}" --query Parameter.Value --output text)"
instance_ids="$(aws autoscaling describe-auto-scaling-groups \
  --region "${region}" \
  --auto-scaling-group-names "${asg_name}" \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' \
  --output text)"
deployed_amis="$(aws ec2 describe-instances \
  --region "${region}" \
  --instance-ids ${instance_ids} \
  --query 'Reservations[].Instances[].ImageId' \
  --output text)"

for deployed_ami in ${deployed_amis}; do
  if [[ "${deployed_ami}" != "${target_ami}" ]]; then
    echo "Expected ${target_ami}, found ${deployed_ami}" >&2
    exit 1
  fi
done

command_id="$(aws ssm send-command \
  --region "${region}" \
  --document-name AWS-RunShellScript \
  --instance-ids ${instance_ids} \
  --parameters 'commands=["cat /etc/asg-refresh-lab-release"]' \
  --query Command.CommandId \
  --output text)"

for instance_id in ${instance_ids}; do
  aws ssm wait command-executed --region "${region}" --command-id "${command_id}" --instance-id "${instance_id}"
  output="$(aws ssm get-command-invocation \
    --region "${region}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query StandardOutputContent \
    --output text)"
  if ! grep -Fxq "release=${expected_release}" <<<"${output}"; then
    echo "${instance_id} has an unexpected marker:" >&2
    echo "${output}" >&2
    exit 1
  fi
  echo "${instance_id} ${target_ami}: release=${expected_release}"
done
