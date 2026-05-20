#!/usr/bin/env bash
# Ambassador pointings helper (macOS-friendly, arrow keys fixed)
# Requires: jq ; Optional: fzf
# It will re-exec itself with Homebrew bash (>=4) to guarantee readline behavior.

set -euo pipefail

# --- Re-exec with Homebrew bash if system bash < 4 (macOS /bin/bash is 3.2) ---
if ! command -v bash >/dev/null 2>&1; then
  echo "bash not found" >&2; exit 1
fi

if [[ -z "${BASH_VERSINFO:-}" ]] || [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  # Prefer arm64 path, then Intel
  for HB in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$HB" ]]; then
      exec "$HB" "$0" "$@"
    fi
  done
  # If we reach here, user doesn't have Homebrew bash; we'll still try to make it work.
fi

# --- Readline: enforce emacs mode + sensible arrow bindings; bracketed paste ---
{ bind 'set editing-mode emacs' >/dev/null 2>&1 || true; } || true
{ bind '"\e[C": forward-char'   >/dev/null 2>&1 || true; } || true  # Right
{ bind '"\e[D": backward-char'  >/dev/null 2>&1 || true; } || true  # Left
{ bind 'set enable-bracketed-paste on' >/dev/null 2>&1 || true; } || true

# ---------------- Config (override via env) ----------------
DEFAULT_DEMO_FQDN="${DEFAULT_DEMO_FQDN:-dev-ambassador-22.birdeye.internal:8080}"
DEFAULT_QA_FQDN="${DEFAULT_QA_FQDN:-qa-ambassador5.birdeye.internal:8080}"
SCHEME="${SCHEME:-http}"  # http or https
LIST_PATH="${LIST_PATH:-/ambassador/admin/list-microservice-endpoint}"
UPDATE_PATH="${UPDATE_PATH:-/ambassador/admin/update-microservice-endpoint}"
CURL_OPTS=(-sS --fail --connect-timeout 5 --max-time 20)

# ---------------- Utilities ----------------
die() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1 (install: brew install $1)"; }

# input editor with *true* arrow-key support:
# - If Bash >=4: use read -e -i (prefilled, fully editable)
# - Else if fzf exists: use fzf as a tiny inline editor with the default as query
# - Else: plain read (no prefill), but still usable
read_edit() {
  local prompt="$1" def="$2" ans=""
  if [[ -n "${BASH_VERSINFO:-}" && "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    # Proper prefilled readline prompt
    read -e -i "$def" -p "$prompt " ans
    printf "\n"  # move to next line after read -p
    echo "${ans:-$def}"
  elif command -v fzf >/dev/null 2>&1; then
    # Use fzf as a single-line editor (arrow keys work inside fzf)
    # First line of output is the edited query
    ans="$(printf "" | fzf --print-query --prompt="$prompt " --query="$def" --height=10% --layout=reverse --border)"
    ans="${ans%%$'\n'*}"
    echo "${ans:-$def}"
  else
    # Basic fallback
    printf "%s [%s]: " "$prompt" "$def" >&2
    IFS= read -r ans || true
    echo "${ans:-$def}"
  fi
}

confirm_yes() {
  local yn=""
  yn="$(read_edit "$1 [y/N]" "")"
  yn="$(echo "${yn:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$yn" == "y" || "$yn" == "yes" ]]
}

pick_menu() {
  local title="$1"; shift
  local -a opts=("$@")
  if command -v fzf >/dev/null 2>&1; then
    printf "%s\n" "${opts[@]}" | fzf --prompt="$title: " --height=30% --border
  else
    echo "$title:"
    local i
    for i in "${!opts[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${opts[$i]}"; done
    local choice; choice="$(read_edit "Enter choice [1-${#opts[@]}]:" "")"
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid choice."
    (( choice>=1 && choice<=${#opts[@]} )) || die "Out of range."
    echo "${opts[$((choice-1))]}"
  fi
}

curl_json() {
  local method="$1" url="$2" data="${3:-}"
  if [[ "$method" == "GET" ]]; then
    curl "${CURL_OPTS[@]}" "$url"
  else
    curl "${CURL_OPTS[@]}" -H "Content-Type: application/json" -d "$data" "$url"
  fi
}

build_base_url() {
  local fqdn="$1"
  [[ "$fqdn" =~ ^https?:// ]] && echo "$fqdn" || echo "${SCHEME}://$fqdn"
}

derive_default_armor_url() {
  local env="$1" amb="$2"
  local host="${amb%:*}" port="${amb##*:}"
  [[ "$host" == "$port" ]] && port="8080"
  local num="X"
  if [[ "$host" =~ -([0-9]+)$ ]]; then num="${BASH_REMATCH[1]}";
  elif [[ "$host" =~ ([0-9]+)$ ]]; then num="${BASH_REMATCH[1]}"; fi
  if [[ "$env" == "demo" ]]; then
    echo "${SCHEME}://dev-armor${num}.birdeye.internal:${port}/health/check"
  elif [[ "$env" == "qa" ]]; then
    echo "${SCHEME}://qa-armor${num}.birdeye.internal:${port}/health/check"
  else
    echo "${SCHEME}://armor.example.internal:${port}/health/check"
  fi
}

# ---------------- Flows ----------------
choose_environment() {
  local choice fqdn
  choice="$(pick_menu "Select environment" "demo" "qa" "custom")"
  case "$choice" in
    demo)   fqdn="$(read_edit "Ambassador FQDN:port for DEMO"   "$DEFAULT_DEMO_FQDN")" ;;
    qa)     fqdn="$(read_edit "Ambassador FQDN:port for QA"     "$DEFAULT_QA_FQDN")" ;;
    custom) fqdn="$(read_edit "Ambassador FQDN:port (custom)"    "$DEFAULT_DEMO_FQDN")" ;;
    *) die "Unknown env choice" ;;
  esac
  echo "$choice|$fqdn"
}

list_pointings() { curl_json GET "$1$LIST_PATH"; }

pick_service_row() {
  local json="$1"
  if command -v fzf >/dev/null 2>&1; then
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$json" | \
      fzf --prompt="Pick service: " --with-nth=1 --delimiter=$'\t' --height=40% --border
  else
    # plain list; user will type the number at the prompt above
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$json"
  fi
}

validate_url() {
  local u="$1"
  [[ "$u" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~:/?#\[\]@!\$&\(\)\*\+,;=%-]*)?$ ]]
}

do_update_flow() {
  local base="$1"
  echo "Fetching current pointings..."
  local before_json; before_json="$(list_pointings "$base")" || die "GET list failed."
  jq -e 'type=="object"' >/dev/null <<<"$before_json" || die "Unexpected GET response (not object)."

  echo
  echo "Current pointings:"
  jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$before_json" | awk -F'\t' '{printf "  %-24s  %s\n",$1,$2}'

  local pick_line
  if command -v fzf >/dev/null 2>&1; then
    pick_line="$(pick_service_row "$before_json")" || die "No selection."
  else
    # manual choose
    local -a systems urls; mapfile -t systems < <(jq -r 'keys[]' <<<"$before_json")
    mapfile -t urls < <(jq -r '.[]' <<<"$before_json")
    local count="${#systems[@]}"; (( count>0 )) || die "No services found."
    local choice; choice="$(read_edit "Enter service number [1-$count]:" "")"
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid choice."
    (( choice>=1 && choice<=count )) || die "Out of range."
    pick_line="${systems[$((choice-1))]}  ${urls[$((choice-1))]}"
  fi

  local system curr_url
  system="$(awk -F$'\t' '{print $1}' <<<"$pick_line")"
  curr_url="$(awk -F$'\t' '{print $2}' <<<"$pick_line")"

  local new_url; new_url="$(read_edit "New URL for ${system}" "$curr_url")"
  if ! validate_url "$new_url"; then
    echo "Warning: URL looks unusual: $new_url"
    confirm_yes "Proceed anyway?" || { echo "Aborted."; return; }
  fi

  echo
  echo "System : $system"
  echo "Old URL: $curr_url"
  echo "New URL: $new_url"
  confirm_yes "Proceed with update?" || { echo "Aborted."; return; }

  local payload; payload="$(jq -n --arg system "$system" --arg url "$new_url" '{system:$system, url:$url}')"

  echo "Updating..."
  local update_res; update_res="$(curl_json POST "${base}${UPDATE_PATH}" "$payload" 2>&1)" || true

  echo "Re-fetching..."
  local after_json; after_json="$(list_pointings "$base")" || die "Second GET failed."
  local new_val; new_val="$(jq -r --arg k "$system" '.[$k] // ""' <<<"$after_json")"

  echo
  echo "----- Result -----"
  if [[ "$new_val" == "$new_url" ]]; then
    echo "✅ Updated: $system"
  else
    echo "⚠️  Update did not reflect as expected for $system"
  fi
  echo "Before: $curr_url"
  echo "After : $new_val"

  echo
  echo "----- Raw update response -----"
  [[ -n "$update_res" ]] && echo "$update_res" || echo "<empty>"
}

do_health_check() {
  local env="$1" amb="$2"
  echo
  echo "Health check"
  local def; def="$(derive_default_armor_url "$env" "$amb")"
  local url; url="$(read_edit "Armor health URL" "$def")"
  echo "GET $url"
  local res; if ! res="$(curl_json GET "$url" 2>&1)"; then
    echo "Request failed:"; echo "$res"; return
  fi
  echo; echo "Raw output:"; echo "$res" | jq .
}

# ---------------- Main ----------------
need jq

echo "== Ambassador Pointings Admin =="

env_and_fqdn="$(choose_environment)"
ENV_LABEL="${env_and_fqdn%%|*}"
AMB_FQDN="${env_and_fqdn##*|}"
BASE_URL="$(build_base_url "$AMB_FQDN")"

echo
echo "Environment : $ENV_LABEL"
echo "Ambassador  : $BASE_URL"
echo

while true; do
  action="$(pick_menu "Choose action" \
    "List services (service + URL)" \
    "Update a service pointing" \
    "Check armor health" \
    "Change environment / Ambassador FQDN" \
    "Quit")"
  case "$action" in
    "List services (service + URL)")
      echo "Fetching pointings..."
      if ! out="$(list_pointings "$BASE_URL")"; then die "GET failed"; fi
      echo; echo "Services:"
      jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$out" | awk -F'\t' '{printf "  %-24s  %s\n",$1,$2}'
      echo
      ;;
    "Update a service pointing")
      do_update_flow "$BASE_URL"; echo
      ;;
    "Check armor health")
      do_health_check "$ENV_LABEL" "$AMB_FQDN"; echo
      ;;
    "Change environment / Ambassador FQDN")
      env_and_fqdn="$(choose_environment)"
      ENV_LABEL="${env_and_fqdn%%|*}"
      AMB_FQDN="${env_and_fqdn##*|}"
      BASE_URL="$(build_base_url "$AMB_FQDN")"
      echo; echo "Environment : $ENV_LABEL"; echo "Ambassador  : $BASE_URL"; echo
      ;;
    "Quit") exit 0 ;;
    *) echo "Unknown option" ;;
  esac
done