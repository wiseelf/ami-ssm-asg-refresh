#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

tf_output() {
  terraform -chdir="${REPO_DIR}" output -raw "$1"
}

aws_region() {
  tf_output aws_region
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_lab_state() {
  require_command terraform
  require_command aws
  terraform -chdir="${REPO_DIR}" output >/dev/null
}
