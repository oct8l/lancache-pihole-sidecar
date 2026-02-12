#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-run}"
ENABLE="${ENABLE:-true}"
ONESHOT="${ONESHOT:-false}"
REMOVE_ON_DISABLE="${REMOVE_ON_DISABLE:-true}"
STRICT_GROUPS="${STRICT_GROUPS:-true}"
INCLUDE_LOCAL_DIRECTIVE="${INCLUDE_LOCAL_DIRECTIVE:-true}"

LANCACHE_IP="${LANCACHE_IP:-}"
DOMAIN_GROUPS="${DOMAIN_GROUPS:-all}"
UPDATE_INTERVAL_SECONDS="${UPDATE_INTERVAL_SECONDS:-21600}"

CACHE_DOMAINS_REPO="${CACHE_DOMAINS_REPO:-https://github.com/uklans/cache-domains.git}"
CACHE_DOMAINS_BRANCH="${CACHE_DOMAINS_BRANCH:-master}"
CACHE_DOMAINS_DIR="${CACHE_DOMAINS_DIR:-/var/lib/lancache-sidecar/cache-domains}"

OUTPUT_FILE="${OUTPUT_FILE:-/etc/dnsmasq.d/99-lancache-sidecar.conf}"
RELOAD_COMMAND="${RELOAD_COMMAND:-}"
PIHOLE_CONTAINER_NAME="${PIHOLE_CONTAINER_NAME:-}"

SCRIPT_NAME="lancache-pihole-sidecar"

log() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"
}

err() {
  printf '[%s] ERROR: %s\n' "${SCRIPT_NAME}" "$*" >&2
}

is_true() {
  case "$(to_lower "$1")" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_interval() {
  if ! [[ "$UPDATE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$UPDATE_INTERVAL_SECONDS" -lt 30 ]]; then
    err "UPDATE_INTERVAL_SECONDS must be an integer >= 30. Received: $UPDATE_INTERVAL_SECONDS"
    exit 1
  fi
}

ensure_directories() {
  mkdir -p "$CACHE_DOMAINS_DIR"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
}

sync_cache_domains() {
  local git_dir="$CACHE_DOMAINS_DIR/.git"

  if [[ ! -d "$git_dir" ]]; then
    log "Cloning cache-domains repository"
    rm -rf "$CACHE_DOMAINS_DIR"
    git clone --depth 1 --branch "$CACHE_DOMAINS_BRANCH" "$CACHE_DOMAINS_REPO" "$CACHE_DOMAINS_DIR"
    return 0
  fi

  log "Updating cache-domains repository"
  git -C "$CACHE_DOMAINS_DIR" remote set-url origin "$CACHE_DOMAINS_REPO"
  git -C "$CACHE_DOMAINS_DIR" fetch --depth 1 origin "$CACHE_DOMAINS_BRANCH"
  git -C "$CACHE_DOMAINS_DIR" checkout -q -B "$CACHE_DOMAINS_BRANCH" "origin/$CACHE_DOMAINS_BRANCH"
}

json_file() {
  printf '%s/cache_domains.json' "$CACHE_DOMAINS_DIR"
}

list_available_groups() {
  local json="$1"
  jq -r '
    if (type == "object") and has("cache_domains") and ((.cache_domains | type) == "array") then
      .cache_domains[]? | .name // empty
    elif type == "array" then
      .[]? | .name // empty
    elif type == "object" then
      keys[]
    else
      empty
    end
  ' "$json"
}

group_exists() {
  local json="$1"
  local group="$2"
  jq -e --arg group "$group" '
    if (type == "object") and has("cache_domains") and ((.cache_domains | type) == "array") then
      any(.cache_domains[]?; (.name // "") == $group)
    elif type == "array" then
      any(.[]?; (.name // "") == $group)
    elif type == "object" then
      has($group)
    else
      false
    end
  ' "$json" >/dev/null
}

domain_files_for_group() {
  local json="$1"
  local group="$2"
  jq -r --arg group "$group" '
    if (type == "object") and has("cache_domains") and ((.cache_domains | type) == "array") then
      .cache_domains[]?
      | select((.name // "") == $group)
      | .domain_files[]?
    elif type == "array" then
      .[]?
      | select((.name // "") == $group)
      | .domain_files[]?
    elif type == "object" then
      .[$group][]?
    else
      empty
    end
  ' "$json"
}

collect_groups() {
  local json
  json="$(json_file)"

  if [[ ! -f "$json" ]]; then
    err "Missing cache_domains.json in $CACHE_DOMAINS_DIR"
    return 1
  fi

  if [[ "$(to_lower "$DOMAIN_GROUPS")" == "all" ]]; then
    list_available_groups "$json"
    return 0
  fi

  local requested raw group
  IFS=',' read -r -a requested <<< "$DOMAIN_GROUPS"

  for raw in "${requested[@]}"; do
    group="$(trim "$raw")"
    [[ -z "$group" ]] && continue

    if group_exists "$json" "$group"; then
      printf '%s\n' "$group"
    elif is_true "$STRICT_GROUPS"; then
      err "Requested DOMAIN_GROUPS entry '$group' does not exist in cache_domains.json"
      return 1
    else
      log "Skipping unknown DOMAIN_GROUPS entry '$group'"
    fi
  done
}

collect_domain_files() {
  local json group
  json="$(json_file)"

  while IFS= read -r group; do
    [[ -z "$group" ]] && continue
    domain_files_for_group "$json" "$group"
  done | sort -u
}

valid_domain_characters() {
  local domain="$1"
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]]
}

sanitize_domain() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%%#*}"
  value="$(trim "$value")"
  value="$(to_lower "$value")"

  [[ -z "$value" ]] && return 1

  # Strip leading wildcard markers or dots.
  while [[ "$value" == \*.* || "$value" == .* ]]; do
    if [[ "$value" == \*.* ]]; then
      value="${value#*.}"
    elif [[ "$value" == .* ]]; then
      value="${value#.}"
    fi
  done

  # Remove trailing dot and CR if present.
  value="${value%.}"
  value="${value%$'\r'}"

  [[ -z "$value" ]] && return 1
  [[ "$value" != *.* ]] && return 1
  valid_domain_characters "$value" || return 1

  printf '%s\n' "$value"
}

collect_domains() {
  local output_file="$1"
  : > "$output_file"

  local file_path line domain
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue

    local absolute_file="$CACHE_DOMAINS_DIR/$file_path"
    if [[ ! -f "$absolute_file" ]]; then
      log "Skipping missing domain file: $file_path"
      continue
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
      domain="$(sanitize_domain "$line" || true)"
      [[ -z "$domain" ]] && continue
      printf '%s\n' "$domain" >> "$output_file"
    done < "$absolute_file"
  done

  sort -u -o "$output_file" "$output_file"
}

collect_ips() {
  local output_file="$1"
  : > "$output_file"

  local raw_parts part ip
  IFS=',' read -r -a raw_parts <<< "$LANCACHE_IP"

  for part in "${raw_parts[@]}"; do
    ip="$(trim "$part")"
    [[ -z "$ip" ]] && continue
    printf '%s\n' "$ip" >> "$output_file"
  done

  sort -u -o "$output_file" "$output_file"

  if [[ ! -s "$output_file" ]]; then
    err "LANCACHE_IP must be set to at least one IP address."
    return 1
  fi
}

generate_dnsmasq_file() {
  local target="$1"
  local temp_domains temp_ips
  temp_domains="$(mktemp)"
  temp_ips="$(mktemp)"

  collect_groups | collect_domain_files | collect_domains "$temp_domains"
  collect_ips "$temp_ips"

  local revision
  revision="$(git -C "$CACHE_DOMAINS_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  {
    printf '# Managed by %s\n' "$SCRIPT_NAME"
    printf '# Source repo: %s\n' "$CACHE_DOMAINS_REPO"
    printf '# Source branch: %s\n' "$CACHE_DOMAINS_BRANCH"
    printf '# Source revision: %s\n\n' "$revision"

    local domain ip
    while IFS= read -r domain; do
      [[ -z "$domain" ]] && continue

      if is_true "$INCLUDE_LOCAL_DIRECTIVE"; then
        printf 'local=/%s/\n' "$domain"
      fi

      while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        printf 'address=/%s/%s\n' "$domain" "$ip"
      done < "$temp_ips"
    done < "$temp_domains"
  } > "$target"

  if [[ ! -s "$temp_domains" ]]; then
    err "No domains were collected from DOMAIN_GROUPS='$DOMAIN_GROUPS'"
    rm -f "$temp_domains" "$temp_ips"
    return 1
  fi

  if [[ ! -s "$target" ]]; then
    err "Generated output is empty"
    rm -f "$temp_domains" "$temp_ips"
    return 1
  fi

  rm -f "$temp_domains" "$temp_ips"
}

run_reload_command() {
  if [[ -n "$RELOAD_COMMAND" ]]; then
    log "Running RELOAD_COMMAND"
    if ! sh -c "$RELOAD_COMMAND"; then
      err "RELOAD_COMMAND failed"
      return 1
    fi
    return 0
  fi

  if [[ -n "$PIHOLE_CONTAINER_NAME" ]]; then
    log "Restarting Pi-hole FTL in container: $PIHOLE_CONTAINER_NAME"
    if ! docker exec "$PIHOLE_CONTAINER_NAME" sh -c 'service pihole-FTL restart || /etc/init.d/pihole-FTL restart'; then
      err "Automatic FTL restart failed for container '$PIHOLE_CONTAINER_NAME'"
      return 1
    fi
    return 0
  fi

  log "No reload method configured. Set PIHOLE_CONTAINER_NAME or RELOAD_COMMAND."
  return 0
}

remove_managed_file_if_present() {
  if [[ -f "$OUTPUT_FILE" ]]; then
    log "Removing managed file: $OUTPUT_FILE"
    rm -f "$OUTPUT_FILE"
    run_reload_command
  else
    log "Managed file is already absent: $OUTPUT_FILE"
  fi
}

apply_changes() {
  local temp_file
  temp_file="$(mktemp)"

  if ! generate_dnsmasq_file "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  if [[ -f "$OUTPUT_FILE" ]] && cmp -s "$temp_file" "$OUTPUT_FILE"; then
    log "No changes detected"
    rm -f "$temp_file"
    return 0
  fi

  mv "$temp_file" "$OUTPUT_FILE"
  chmod 0644 "$OUTPUT_FILE"
  log "Updated managed file: $OUTPUT_FILE"
  run_reload_command
}

reconcile_once() {
  if ! is_true "$ENABLE"; then
    log "ENABLE=false. Sidecar will remove managed records if present."
    if is_true "$REMOVE_ON_DISABLE"; then
      remove_managed_file_if_present
    fi
    return 0
  fi

  if [[ -z "$LANCACHE_IP" ]]; then
    err "ENABLE=true but LANCACHE_IP is empty"
    return 1
  fi

  if ! sync_cache_domains; then
    err "Failed to sync cache-domains repository"
    return 1
  fi

  apply_changes
}

main() {
  local mode
  mode="$(to_lower "$MODE")"

  case "$mode" in
    rollback|disable)
      remove_managed_file_if_present
      log "Rollback complete"
      exit 0
      ;;
    run)
      validate_interval
      ensure_directories
      ;;
    *)
      err "Unsupported MODE='$MODE'. Use 'run' or 'rollback'."
      exit 1
      ;;
  esac

  while true; do
    if ! reconcile_once; then
      err "Reconciliation failed"
      if is_true "$ONESHOT"; then
        exit 1
      fi
    fi

    if is_true "$ONESHOT"; then
      log "ONESHOT=true. Exiting after one run."
      exit 0
    fi

    sleep "$UPDATE_INTERVAL_SECONDS"
  done
}

main "$@"
