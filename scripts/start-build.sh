#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

region="$(aws_region)"
pipeline_arn="$(tf_output image_pipeline_arn)"

build_arn="$(aws imagebuilder start-image-pipeline-execution \
  --region "${region}" \
  --image-pipeline-arn "${pipeline_arn}" \
  --query imageBuildVersionArn \
  --output text)"

echo "${build_arn}"
echo "Track it with: aws imagebuilder get-image --region ${region} --image-build-version-arn ${build_arn}"
