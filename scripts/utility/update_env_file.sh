#!/usr/bin/env bash
# Category: Utility
# Description: Script to update the .env file from .env.example / .env.example.merge while preserving existing values.
# Usage: ./scripts/utility/update_env_file.sh [template_env_file]
# Dependencies: cp, sed, grep, awk

set -e
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH_TO_ROOT_REPOSITORY="$(cd "${CURRENT_DIR}/../.." && pwd)"
SERVICE_NAME="$(basename "$PATH_TO_ROOT_REPOSITORY")"
REPOSITORY_OWNER="$(stat -c '%U' "$PATH_TO_ROOT_REPOSITORY" 2>/dev/null || whoami)"

# Configuration
ENV_FILE="${PATH_TO_ROOT_REPOSITORY}/.env"
MAX_BACKUPS=3

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info()    { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn()    { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error()   { log "${COLOR_ERROR}" "❌" "$1"; }

generate_random_hex() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${len}"
  else
    python3 -c "import secrets; print(secrets.token_hex(${len}))" 2>/dev/null || date +%s%N | sha256sum | head -c "$((len * 2))"
  fi
}

function main() {
  TEMPLATE_ENV_FILE="${1:-${PATH_TO_ROOT_REPOSITORY}/.env.example}"

  echo "-------------------------------------------------------------------------------"
  echo " UPDATE ENV FILE FOR $SERVICE_NAME @ $(date +"%A, %d %B %Y %H:%M %Z")"
  echo "-------------------------------------------------------------------------------"

  if ! cd "$PATH_TO_ROOT_REPOSITORY"; then
    log_error "Failed to change directory to $PATH_TO_ROOT_REPOSITORY"
    exit 1
  fi

  if [ -f "$PATH_TO_ROOT_REPOSITORY/.env" ]; then
    TIMESTAMP=$(date +"%Y%m%d%H%M%S")
    BACKUP_NAME=".env.backup_${TIMESTAMP}"

    log_info "Existing .env found. Creating persistent backup: ${BACKUP_NAME}"
    cp .env "$BACKUP_NAME"
    chown "$REPOSITORY_OWNER": "$BACKUP_NAME" 2>/dev/null || true

    # Rotate backups: Keep only the MAX_BACKUPS most recent ones
    BACKUP_COUNT=$(ls -1 .env.backup_* 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        log_info "Rotating backups (limit $MAX_BACKUPS)..."
        ls -1t .env.backup_* | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --
    fi
  else
    log_warn ".env file not found. Backup skipped."
  fi

  if [ -f "$TEMPLATE_ENV_FILE" ]; then
    log_info "Copying $TEMPLATE_ENV_FILE to .env..."
    cp "$TEMPLATE_ENV_FILE" .env
  else
    log_error "Source template file not found: $TEMPLATE_ENV_FILE"
    exit 1
  fi

  # Find the most recent backup file
  LATEST_BACKUP=$(ls -1t .env.backup_* 2>/dev/null | head -n 1 || true)

  if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
    log_info "Importing existing values from $LATEST_BACKUP to .env..."
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[a-zA-Z_]+[a-zA-Z0-9_]*= ]]; then
        variable_name=$(echo "$line" | cut -d'=' -f1)
        variable_value=$(echo "$line" | cut -d'=' -f2-)

        if grep -q "^$variable_name=" .env && [ -n "$variable_value" ]; then
          log_info "Preserving existing $variable_name"
          # Safe sed replacement escape
          escaped_val=$(printf '%s\n' "$variable_value" | sed -e 's/[\/&]/\\&/g')
          sed -i "s|^$variable_name=.*|$variable_name=$escaped_val|" .env
        fi
      fi
    done < "$LATEST_BACKUP"
  else
    log_warn "No backup file found. Importing skipped."
  fi

  # Auto-generate secure random values for common security tokens if still using default placeholders
  local secret_key_val
  secret_key_val=$(grep -E '^SECRET_KEY=' .env 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')
  if [ "$secret_key_val" = "change-this-to-a-secure-random-secret-key" ] || [ -z "$secret_key_val" ]; then
    local new_sec
    new_sec=$(generate_random_hex 32)
    sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${new_sec}|" .env
    log_success "Generated secure SECRET_KEY in .env"
  fi

  local connector_token_val
  connector_token_val=$(grep -E '^CONNECTOR_TOKEN=' .env 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')
  if [[ "$connector_token_val" =~ (ganti_|isi_|change_) ]] || [ -z "$connector_token_val" ]; then
    local new_token
    new_token=$(generate_random_hex 32)
    sed -i "s|^CONNECTOR_TOKEN=.*|CONNECTOR_TOKEN=${new_token}|" .env
    log_success "Generated secure CONNECTOR_TOKEN in .env"
  fi

  local session_secret_val
  session_secret_val=$(grep -E '^SESSION_SECRET=' .env 2>/dev/null | cut -d '=' -f2- | tr -d ' "\r\n' || echo '')
  if [[ "$session_secret_val" =~ (ganti_|isi_|change_) ]] || [ -z "$session_secret_val" ]; then
    local new_session
    new_session=$(generate_random_hex 32)
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=${new_session}|" .env
    log_success "Generated secure SESSION_SECRET in .env"
  fi

  log_info "Updating .env file ownership..."
  chown "$REPOSITORY_OWNER": .env 2>/dev/null || true

  log_success "Update finished successfully."
}

main "$@"
