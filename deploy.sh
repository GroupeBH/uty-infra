#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
GENERATED_BACKEND_FILE="$TERRAFORM_DIR/.generated-backend.tf"
SSH_USER="${SSH_USER:-ubuntu}"
DEFAULT_APP_ENV_FILE="$SCRIPT_DIR/.env.production"

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [options]

Supported environment variables and flags:
  AWS_REGION / --aws-region
  KEY_NAME / --key-name
  PRIVATE_KEY_PATH / --private-key-path
  ADMIN_CIDR / --admin-cidr
  DOMAIN / --domain
  CADDY_EMAIL / --caddy-email
  INSTANCE_NAME / --instance-name
  INSTANCE_TYPE / --instance-type
  APP_IMAGE_REPOSITORY / --app-image-repository
  APP_IMAGE_TAG / --app-image-tag
  APP_ENV_FILE / --app-env-file
  APP_HEALTHCHECK_PATH / --app-healthcheck-path
  TF_VARS_FILE / --tf-vars-file
  TF_BACKEND_CONFIG_FILE / --tf-backend-config-file
  TF_STATE_BUCKET / --tf-state-bucket
  TF_STATE_KEY / --tf-state-key
  TF_STATE_REGION / --tf-state-region
  TF_LOCK_TABLE / --tf-lock-table

Notes:
  - If APP_ENV_FILE is not provided and ./.env.production exists, deploy.sh uses it as the application env file.
  - APP_ENV_FILE is copied to the instances for the NestJS container but is not sourced locally for Terraform or Ansible control-plane configuration.
  - If your shell exports temporary AWS credentials and AWS_ACCESS_KEY_ID starts with ASIA, AWS_SESSION_TOKEN must also be present.
EOF
}

log() {
  printf '[deploy] %s\n' "$*"
}

fail() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

resolve_path() {
  local input="$1"
  if [[ "$input" != /* ]]; then
    input="$PWD/$input"
  fi
  local dir
  dir="$(cd "$(dirname "$input")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$input")"
}

append_tf_var() {
  local tf_name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    TF_APPLY_ARGS+=("-var" "${tf_name}=${value}")
  fi
}

yaml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

json_string_array() {
  local item
  local first=true
  printf '['
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$(json_escape "$item")"
  done
  printf ']'
}

validate_aws_credentials() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    if [[ "$AWS_ACCESS_KEY_ID" == ASIA* && -z "${AWS_SESSION_TOKEN:-}" ]]; then
      fail "Temporary AWS credentials detected in the current shell (AWS_ACCESS_KEY_ID starts with ASIA) but AWS_SESSION_TOKEN is missing. Add AWS_SESSION_TOKEN to your shell, use AWS_PROFILE, or unset AWS_* variables before rerunning deploy.sh."
    fi

    log "Using AWS credentials from the current shell environment."
  elif [[ -n "${AWS_PROFILE:-}" ]]; then
    log "Using AWS profile ${AWS_PROFILE}."
  else
    log "Using the default AWS credential chain."
  fi

  if command -v aws >/dev/null 2>&1; then
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
      fail "AWS credential preflight failed. Refresh your shell credentials or fix AWS_SESSION_TOKEN/AWS_PROFILE before rerunning deploy.sh."
    fi
  fi
}

terraform_output_raw() {
  terraform -chdir="$TERRAFORM_DIR" output -raw "$1"
}

wait_for_ssh() {
  local host="$1"
  local max_attempts=60
  local attempt=1

  while (( attempt <= max_attempts )); do
    if ssh \
      -i "$PRIVATE_KEY_PATH" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "$SSH_USER@$host" true >/dev/null 2>&1; then
      log "SSH is ready on $host"
      return 0
    fi

    sleep 5
    attempt=$((attempt + 1))
  done

  return 1
}

prepare_ssh_firewall_with_ssm() {
  [[ -n "${DEPLOY_INSTANCE_IDS_CSV:-}" ]] || return 0
  [[ -n "${DEPLOY_ADMIN_CIDRS_CSV:-}" ]] || return 0

  if ! command -v aws >/dev/null 2>&1; then
    log "AWS CLI not found; skipping SSM SSH firewall preflight."
    return 0
  fi

  local -a instance_ids
  local -a admin_cidrs
  local -a commands
  local instance_id
  local cidr
  local ssm_payload
  local command_id

  IFS=',' read -r -a instance_ids <<< "$DEPLOY_INSTANCE_IDS_CSV"
  IFS=',' read -r -a admin_cidrs <<< "$DEPLOY_ADMIN_CIDRS_CSV"

  commands=("set -eu")
  for cidr in "${admin_cidrs[@]}"; do
    [[ -n "$cidr" ]] || continue
    commands+=("if command -v ufw >/dev/null 2>&1; then ufw allow from $cidr to any port 22 proto tcp; fi")
  done

  [[ "${#instance_ids[@]}" -gt 0 ]] || return 0
  [[ "${#commands[@]}" -gt 1 ]] || return 0

  log "Preparing SSH firewall rules through AWS SSM"
  ssm_payload="$(mktemp)"
  {
    printf '{'
    printf '"DocumentName":"AWS-RunShellScript",'
    printf '"InstanceIds":'
    json_string_array "${instance_ids[@]}"
    printf ','
    printf '"Parameters":{"commands":'
    json_string_array "${commands[@]}"
    printf '},'
    printf '"Comment":"Allow deployment SSH CIDRs before Ansible"'
    printf '}'
  } > "$ssm_payload"

  if ! command_id="$(aws ssm send-command \
    --region "$DEPLOY_REGION" \
    --cli-input-json "file://$ssm_payload" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)"; then
    rm -f "$ssm_payload"
    log "SSM SSH firewall preflight could not be started; continuing with direct SSH checks."
    return 0
  fi

  rm -f "$ssm_payload"

  for instance_id in "${instance_ids[@]}"; do
    [[ -n "$instance_id" ]] || continue
    if ! aws ssm wait command-executed \
      --region "$DEPLOY_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" 2>/dev/null; then
      log "SSM SSH firewall preflight did not complete on $instance_id; continuing with direct SSH checks."
    fi
  done
}

AWS_REGION="${AWS_REGION:-}"
KEY_NAME="${KEY_NAME:-}"
PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-}"
ADMIN_CIDR="${ADMIN_CIDR:-}"
DOMAIN="${DOMAIN:-}"
CADDY_EMAIL="${CADDY_EMAIL:-}"
INSTANCE_NAME="${INSTANCE_NAME:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
APP_IMAGE_REPOSITORY="${APP_IMAGE_REPOSITORY:-}"
APP_IMAGE_TAG="${APP_IMAGE_TAG:-}"
APP_ENV_FILE="${APP_ENV_FILE:-}"
APP_HEALTHCHECK_PATH="${APP_HEALTHCHECK_PATH:-}"
TF_VARS_FILE="${TF_VARS_FILE:-}"
TF_BACKEND_CONFIG_FILE="${TF_BACKEND_CONFIG_FILE:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-}"
TF_STATE_REGION="${TF_STATE_REGION:-}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-region)
      AWS_REGION="$2"
      shift 2
      ;;
    --key-name)
      KEY_NAME="$2"
      shift 2
      ;;
    --private-key-path)
      PRIVATE_KEY_PATH="$2"
      shift 2
      ;;
    --admin-cidr)
      ADMIN_CIDR="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --caddy-email)
      CADDY_EMAIL="$2"
      shift 2
      ;;
    --instance-name)
      INSTANCE_NAME="$2"
      shift 2
      ;;
    --instance-type)
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    --app-image-repository)
      APP_IMAGE_REPOSITORY="$2"
      shift 2
      ;;
    --app-image-tag)
      APP_IMAGE_TAG="$2"
      shift 2
      ;;
    --app-env-file)
      APP_ENV_FILE="$2"
      shift 2
      ;;
    --app-healthcheck-path)
      APP_HEALTHCHECK_PATH="$2"
      shift 2
      ;;
    --tf-vars-file)
      TF_VARS_FILE="$2"
      shift 2
      ;;
    --tf-backend-config-file)
      TF_BACKEND_CONFIG_FILE="$2"
      shift 2
      ;;
    --tf-state-bucket)
      TF_STATE_BUCKET="$2"
      shift 2
      ;;
    --tf-state-key)
      TF_STATE_KEY="$2"
      shift 2
      ;;
    --tf-state-region)
      TF_STATE_REGION="$2"
      shift 2
      ;;
    --tf-lock-table)
      TF_LOCK_TABLE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "$APP_ENV_FILE" && -f "$DEFAULT_APP_ENV_FILE" ]]; then
  APP_ENV_FILE="$DEFAULT_APP_ENV_FILE"
fi

if [[ -z "$TF_VARS_FILE" && -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
  TF_VARS_FILE="$TERRAFORM_DIR/terraform.tfvars"
fi

if [[ -z "$TF_BACKEND_CONFIG_FILE" && -f "$TERRAFORM_DIR/backend.hcl" ]]; then
  TF_BACKEND_CONFIG_FILE="$TERRAFORM_DIR/backend.hcl"
fi

require_command terraform
require_command ansible-playbook
require_command ssh

[[ -n "$PRIVATE_KEY_PATH" ]] || fail "PRIVATE_KEY_PATH is required."
[[ -f "$PRIVATE_KEY_PATH" ]] || fail "PRIVATE_KEY_PATH does not point to a file."
PRIVATE_KEY_PATH="$(resolve_path "$PRIVATE_KEY_PATH")"

if [[ -n "$APP_ENV_FILE" ]]; then
  [[ -f "$APP_ENV_FILE" ]] || fail "APP_ENV_FILE does not point to a file."
  APP_ENV_FILE="$(resolve_path "$APP_ENV_FILE")"
  log "Using application env file $APP_ENV_FILE"
fi

if [[ -n "$TF_VARS_FILE" ]]; then
  [[ -f "$TF_VARS_FILE" ]] || fail "TF_VARS_FILE does not point to a file."
  TF_VARS_FILE="$(resolve_path "$TF_VARS_FILE")"
fi

if [[ -n "$TF_BACKEND_CONFIG_FILE" ]]; then
  [[ -f "$TF_BACKEND_CONFIG_FILE" ]] || fail "TF_BACKEND_CONFIG_FILE does not point to a file."
  TF_BACKEND_CONFIG_FILE="$(resolve_path "$TF_BACKEND_CONFIG_FILE")"
fi

validate_aws_credentials

TF_INIT_ARGS=(-input=false -reconfigure)
if [[ -n "$TF_BACKEND_CONFIG_FILE" || -n "$TF_STATE_BUCKET" || -n "$TF_STATE_KEY" || -n "$TF_STATE_REGION" || -n "$TF_LOCK_TABLE" ]]; then
  cat > "$GENERATED_BACKEND_FILE" <<'EOF'
terraform {
  backend "s3" {}
}
EOF

  [[ -n "$TF_BACKEND_CONFIG_FILE" ]] && TF_INIT_ARGS+=("-backend-config=$TF_BACKEND_CONFIG_FILE")
  [[ -n "$TF_STATE_BUCKET" ]] && TF_INIT_ARGS+=("-backend-config=bucket=$TF_STATE_BUCKET")
  [[ -n "$TF_STATE_KEY" ]] && TF_INIT_ARGS+=("-backend-config=key=$TF_STATE_KEY")
  [[ -n "$TF_STATE_REGION" ]] && TF_INIT_ARGS+=("-backend-config=region=$TF_STATE_REGION")
  [[ -n "$TF_LOCK_TABLE" ]] && TF_INIT_ARGS+=("-backend-config=dynamodb_table=$TF_LOCK_TABLE")
else
  rm -f "$GENERATED_BACKEND_FILE"
fi

TF_APPLY_ARGS=(-input=false -auto-approve)
[[ -n "$TF_VARS_FILE" ]] && TF_APPLY_ARGS+=("-var-file=$TF_VARS_FILE")
append_tf_var aws_region "$AWS_REGION"
append_tf_var key_name "$KEY_NAME"
append_tf_var admin_cidr "$ADMIN_CIDR"
append_tf_var domain_name "$DOMAIN"
append_tf_var caddy_email "$CADDY_EMAIL"
append_tf_var instance_name "$INSTANCE_NAME"
append_tf_var instance_type "$INSTANCE_TYPE"
append_tf_var app_image_repository "$APP_IMAGE_REPOSITORY"
append_tf_var app_image_tag "$APP_IMAGE_TAG"
append_tf_var app_healthcheck_path "$APP_HEALTHCHECK_PATH"

log "Running terraform init"
terraform -chdir="$TERRAFORM_DIR" init "${TF_INIT_ARGS[@]}"

log "Running terraform apply"
terraform -chdir="$TERRAFORM_DIR" apply "${TF_APPLY_ARGS[@]}"

log "Reading Terraform outputs"
PRIMARY_IP="$(terraform_output_raw deploy_primary_public_ip)"
PRIMARY_PRIVATE_IP="$(terraform_output_raw deploy_primary_private_ip)"
SECONDARY_ENABLED="$(terraform_output_raw deploy_secondary_enabled)"
SECONDARY_IP="$(terraform_output_raw deploy_secondary_public_ip || true)"
SECONDARY_PRIVATE_IP="$(terraform_output_raw deploy_secondary_private_ip || true)"
DEPLOY_REGION="$(terraform_output_raw deploy_region)"
DEPLOY_ADMIN_CIDRS="$(terraform -chdir="$TERRAFORM_DIR" output -json deploy_admin_cidrs)"
DEPLOY_ADMIN_CIDRS_CSV="$(terraform_output_raw deploy_admin_cidrs_csv)"
DEPLOY_INSTANCE_IDS_CSV="$(terraform_output_raw deploy_instance_ids_csv)"
DEPLOY_INSTANCE_NAME="$(terraform_output_raw deploy_instance_name)"
DEPLOY_DOMAIN_NAME="$(terraform_output_raw deploy_domain_name || true)"
DEPLOY_CADDY_EMAIL="$(terraform_output_raw deploy_caddy_email || true)"
DEPLOY_APP_IMAGE_REPOSITORY="$(terraform_output_raw deploy_app_image_repository)"
DEPLOY_APP_IMAGE_TAG="$(terraform_output_raw deploy_app_image_tag)"
DEPLOY_APP_HEALTHCHECK_PATH="$(terraform_output_raw deploy_app_healthcheck_path)"

log "Generating Ansible inventory"
cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[app]
primary ansible_host=$PRIMARY_IP ansible_user=$SSH_USER instance_name=$DEPLOY_INSTANCE_NAME private_ip=$PRIMARY_PRIVATE_IP
EOF

if [[ "$SECONDARY_ENABLED" == "true" && -n "$SECONDARY_IP" ]]; then
  printf 'secondary ansible_host=%s ansible_user=%s instance_name=%s private_ip=%s\n' \
    "$SECONDARY_IP" \
    "$SSH_USER" \
    "${DEPLOY_INSTANCE_NAME}-secondary" \
  "$SECONDARY_PRIVATE_IP" >> "$ANSIBLE_DIR/inventory.ini"
fi

prepare_ssh_firewall_with_ssm

log "Waiting for SSH on primary ($PRIMARY_IP)"
wait_for_ssh "$PRIMARY_IP" || fail "SSH did not become ready on primary node."

if [[ "$SECONDARY_ENABLED" == "true" && -n "$SECONDARY_IP" ]]; then
  log "Waiting for SSH on secondary ($SECONDARY_IP)"
  wait_for_ssh "$SECONDARY_IP" || fail "SSH did not become ready on secondary node."
fi

EXTRA_VARS_FILE="$(mktemp)"
trap 'rm -f "$EXTRA_VARS_FILE"' EXIT
cat > "$EXTRA_VARS_FILE" <<EOF
admin_cidrs: $DEPLOY_ADMIN_CIDRS
aws_region: "$(yaml_escape "$DEPLOY_REGION")"
domain_name: "$(yaml_escape "$DEPLOY_DOMAIN_NAME")"
caddy_email: "$(yaml_escape "$DEPLOY_CADDY_EMAIL")"
app_image_repository: "$(yaml_escape "$DEPLOY_APP_IMAGE_REPOSITORY")"
app_image_tag: "$(yaml_escape "$DEPLOY_APP_IMAGE_TAG")"
app_healthcheck_path: "$(yaml_escape "$DEPLOY_APP_HEALTHCHECK_PATH")"
app_env_file: "$(yaml_escape "$APP_ENV_FILE")"
EOF

log "Running ansible-playbook"
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i "$ANSIBLE_DIR/inventory.ini" \
  --private-key "$PRIVATE_KEY_PATH" \
  --extra-vars "@$EXTRA_VARS_FILE" \
  "$ANSIBLE_DIR/playbook.yml"

log "Deployment completed"
log "Primary public ingress target: $PRIMARY_IP"
if [[ "$SECONDARY_ENABLED" == "true" && -n "$SECONDARY_IP" ]]; then
  log "Additional public ingress target: $SECONDARY_IP"
fi
