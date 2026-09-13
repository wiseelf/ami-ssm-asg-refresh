#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

region="$(aws_region)"
function_name="$(tf_output lambda_function_name)"
response_file="$(mktemp)"
trap 'rm -f -- "${response_file}"' EXIT

aws lambda invoke \
  --region "${region}" \
  --function-name "${function_name}" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"mode":"reconcile"}' \
  "${response_file}" >/dev/null

cat "${response_file}"
echo
