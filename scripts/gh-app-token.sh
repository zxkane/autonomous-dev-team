#!/bin/bash
# gh-app-token.sh — Generate a GitHub App installation token.
#
# Shared module for autonomous-dev.sh and autonomous-review.sh.
# Generates a JWT from the App's private key, then exchanges it for
# an installation access token scoped to the repository.
#
# Usage (source this file):
#   source "$(dirname "$0")/gh-app-token.sh"
#   GH_TOKEN=$(get_gh_app_token "$APP_ID" "$PEM_FILE" "$REPO_OWNER" "$REPO_NAME")
#   export GH_TOKEN  # gh CLI will use this automatically
#
# Requirements:
#   - openssl (for RS256 signing)
#   - curl
#   - Python 3 (for base64url encoding and JSON parsing)

# Generate RS256 JWT for GitHub App authentication.
# Args: $1=app_id, $2=pem_file
_generate_jwt() {
  local app_id="$1"
  local pem_file="$2"

  # Validate app_id is numeric
  if ! [[ "$app_id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: app_id must be numeric, got '$app_id'" >&2
    return 1
  fi

  # Prevent path traversal in PEM file path
  if [[ "$pem_file" == *".."* ]]; then
    echo "ERROR: PEM file path contains invalid sequences" >&2
    return 1
  fi

  if [[ ! -f "$pem_file" ]]; then
    echo "ERROR: PEM file not found: $pem_file" >&2
    return 1
  fi

  # Check required commands
  for cmd in python3 openssl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "ERROR: Required command '$cmd' not found in PATH" >&2
      return 1
    }
  done

  local now
  now=$(date +%s)
  local iat=$((now - 60))
  local exp=$((now + 600))  # 10 minutes max

  # Base64url encode helper
  _b64url() {
    python3 -c "import sys, base64; data=sys.stdin.buffer.read(); print(base64.urlsafe_b64encode(data).rstrip(b'=').decode())"
  }

  local header='{"alg":"RS256","typ":"JWT"}'
  local payload="{\"iss\":${app_id},\"iat\":${iat},\"exp\":${exp}}"

  local header_b64 payload_b64
  header_b64=$(printf '%s' "$header" | _b64url) || {
    echo "ERROR: Failed to base64url-encode JWT header" >&2; return 1
  }
  payload_b64=$(printf '%s' "$payload" | _b64url) || {
    echo "ERROR: Failed to base64url-encode JWT payload" >&2; return 1
  }

  local unsigned="${header_b64}.${payload_b64}"

  # Pipeline directly — bash command substitution strips null bytes from
  # binary openssl output, which corrupts signatures. Pipe directly instead.
  local signature
  signature=$(set -o pipefail; printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$pem_file" | _b64url) || {
    echo "ERROR: openssl signing or base64url encoding failed for PEM: $pem_file" >&2; return 1
  }

  echo "${unsigned}.${signature}"
}

# Parse a JSON field from stdin, with error details on failure.
# Args: $1=field_name, $2=context (for error messages)
_parse_json_field() {
  local field="$1"
  local context="$2"

  # Validate field name to prevent shell→python injection
  if ! [[ "$field" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: invalid field name '$field'" >&2
    return 1
  fi

  python3 -c "
import sys, json
field = '$field'
data = json.load(sys.stdin)
if field not in data:
    msg = data.get('message', 'field not found')
    print(f'API error ($context): {msg}', file=sys.stderr)
    sys.exit(1)
val = data[field]
if val is None:
    print(f'ERROR: field {field} is null', file=sys.stderr)
    sys.exit(1)
print(val)
"
}

# Get a GitHub App installation token for a specific repository.
# Args: $1=app_id, $2=pem_file, $3=repo_owner, $4=repo_name
# Outputs the token string to stdout.
get_gh_app_token() {
  local app_id="$1"
  local pem_file="$2"
  local repo_owner="$3"
  local repo_name="$4"

  # Validate repo_owner and repo_name contain only safe characters
  if ! [[ "$repo_owner" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: repo_owner contains invalid characters: '$repo_owner'" >&2
    return 1
  fi
  if ! [[ "$repo_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "ERROR: repo_name contains invalid characters: '$repo_name'" >&2
    return 1
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: Required command 'curl' not found in PATH" >&2
    return 1
  }

  local jwt
  jwt=$(_generate_jwt "$app_id" "$pem_file") || return 1

  # Find the installation ID for this repository
  local install_response
  install_response=$(curl -s \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -w "\n%{http_code}" \
    "https://api.github.com/repos/${repo_owner}/${repo_name}/installation")

  local http_code
  http_code=$(echo "$install_response" | tail -1)
  install_response=$(echo "$install_response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "ERROR: GitHub API returned HTTP $http_code for installation lookup. Body: $install_response" >&2
    return 1
  fi

  local installation_id
  installation_id=$(echo "$install_response" | _parse_json_field "id" "installation lookup") || {
    echo "ERROR: Failed to parse installation ID. Response: $install_response" >&2
    return 1
  }

  # Exchange JWT for an installation access token
  local token_response
  token_response=$(curl -s \
    -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -w "\n%{http_code}" \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" \
    -d "{\"repositories\":[\"${repo_name}\"]}")

  http_code=$(echo "$token_response" | tail -1)
  token_response=$(echo "$token_response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "ERROR: GitHub API returned HTTP $http_code for token exchange. Body: $token_response" >&2
    return 1
  fi

  local token
  token=$(echo "$token_response" | _parse_json_field "token" "token exchange") || {
    echo "ERROR: Failed to parse token. Response: $token_response" >&2
    return 1
  }

  if [[ -z "$token" ]]; then
    echo "ERROR: Parsed token is empty" >&2
    return 1
  fi

  echo "$token"
}
