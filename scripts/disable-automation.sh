#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_lab_state

aws events disable-rule \
  --region "$(aws_region)" \
  --name "$(tf_output event_rule_name)"
echo "EventBridge rule disabled."
