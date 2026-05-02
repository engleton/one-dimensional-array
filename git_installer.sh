#!/usr/bin/env bash
# git_installer.sh - Clone GitHub repositories and run vetted installers safely.
# Usage:
#   ./git_installer.sh [--dry-run]

set -Eeuo pipefail

# -----------------------------
# Configuration
# -----------------------------
ALLOWED_ROOT="${ALLOWED_ROOT:-$HOME/Developer2}"
VENV_DIR="${VENV_DIR:-$HOME/Developer2/myenv}"
LOG_DIR="${LOG_DIR:-$HOME/Developer2/NewSoftware_Logs}"
STATUS_DIR="${STATUS_DIR:-$HOME/Developer2/NewSoftware_Scripts}"
BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-$HOME/Developer2/NewSoftware_Backups}"

FORCE_TOKEN="${FORCE_TOKEN:-I_CONFIRM_RUN}"            # override dangerous patterns
OVERRIDE_OUTSIDE_TOKEN="${OVERRIDE_OUTSIDE_TOKEN:-I_RUN_OUTSIDE}" # override out-of-root installer

DRY_RUN=0
REPOS=()

mkdir -p "$LOG_DIR" "$STATUS_DIR" "$BACKUP_DIR_BASE" "$ALLOWED_ROOT"

# -----------------------------
# Helpers
# -----------------------------
timestamp() { date '+%Y%m%d-%H%M%S'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*"; }
warn() { printf '⚠️ %s\n' "$*"; }
err() { printf '❌ %s\n' "$*"; }

cleanup() {
  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    deactivate || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<USAGE
Usage: $0 [--dry-run] [repo1 repo2 ...]

Examples:
  $0 --dry-run
  $0 https://github.com/user/repo1.git git clone https://github.com/user/repo2.git
USAGE
}

is_under_allowed_root() {
  local p="$1"
  [[ "$p" == "$ALLOWED_ROOT"/* ]]
}

normalize_repo_input() {
  # Accept either "https://..." or "git clone https://..."
  local raw="$1"
  if [[ "$raw" =~ ^git[[:space:]]+clone[[:space:]]+(https://[^[:space:]]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^https:// ]]; then
    printf '%s\n' "$raw"
  else
    return 1
  fi
}

contains_dangerous_patterns() {
  local file="$1"
  local patterns=(
    'rm -rf /'
    'rm -rf --no-preserve-root /'
    'rm -rf \$HOME'
    'dd if='
    'mkfs(\\.| )'
    ':\s*> /dev/'
    '>: /dev/'
    '\bshutdown\b'
    '\breboot\b'
    'curl .*\|[[:space:]]*sh'
    'wget .*\|[[:space:]]*sh'
    '\bsudo\b'
    'chown .* /(usr|Applications)'
    'chmod .* /(usr|Applications)'
    'mv .* /(usr|Applications)'
  )

  local hit=0
  for p in "${patterns[@]}"; do
    if grep -E -n -- "$p" "$file" >/dev/null 2>&1; then
      echo "  - matched: $p"
      hit=1
    fi
  done

  return "$hit"
}

backup_files() {
  local ts backup_dir
  ts="$(timestamp)"
  backup_dir="$BACKUP_DIR_BASE/backup_$ts"
  mkdir -p "$backup_dir"
  log "Creating backup directory $backup_dir"

  local f
  for f in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    if [[ -f "$f" ]]; then
      cp -a "$f" "$backup_dir/$(basename "$f").bak.$ts"
      log "Backed up $f"
    fi
  done

  while IFS= read -r -d '' envf; do
    mkdir -p "$backup_dir/env_files"
    cp -a "$envf" "$backup_dir/env_files/$(basename "$envf").bak.$ts"
    log "Backed up $envf"
  done < <(find "$ALLOWED_ROOT" -maxdepth 6 -type f -iname '.env' -print0 2>/dev/null)
}

preview_script_head() {
  local script="$1"
  echo "----- preview: first 12 lines of $script -----"
  head -n 12 "$script" || true
  echo "-----------------------------------------------"
}

install_python_deps() {
  local dir="$1" dep_log="$2"
  if [[ -f "$dir/requirements.txt" ]]; then
    log "Installing Python requirements from $dir/requirements.txt"
    python -m pip install -r "$dir/requirements.txt" 2>&1 | tee -a "$dep_log"
  elif [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" || -f "$dir/setup.cfg" ]]; then
    log "Installing Python project in editable mode from $dir"
    python -m pip install -e "$dir" 2>&1 | tee -a "$dep_log"
  fi
}

install_node_deps() {
  local dir="$1" dep_log="$2"
  if [[ -f "$dir/package-lock.json" || -f "$dir/npm-shrinkwrap.json" ]]; then
    if command -v npm >/dev/null 2>&1; then
      log "Running npm ci in $dir"
      (cd "$dir" && npm ci 2>&1 | tee -a "$dep_log")
    else
      warn "npm not installed; skipping npm dependencies for $dir"
    fi
  elif [[ -f "$dir/package.json" ]]; then
    if command -v npm >/dev/null 2>&1; then
      log "Running npm install in $dir (no lockfile present)"
      (cd "$dir" && npm install 2>&1 | tee -a "$dep_log")
    else
      warn "npm not installed; skipping npm dependencies for $dir"
    fi
  fi
}

write_status_files_init() {
  mv "$STATUS_DIR/install_skipped.txt" "$STATUS_DIR/install_skipped.txt.bak" 2>/dev/null || true
  mv "$STATUS_DIR/install_completed.txt" "$STATUS_DIR/install_completed.txt.bak" 2>/dev/null || true
  : > "$STATUS_DIR/install_skipped.txt"
  : > "$STATUS_DIR/install_completed.txt"
}

append_summary_json() {
  local summary="$1" repo="$2" logf="$3" depf="$4" rc="$5"
  jq --arg installer "$repo" --arg log "$logf" --arg deps_log "$depf" --argjson rc "$rc" --arg ts "$(date -u +%FT%TZ)" \
    '. += [{installer:$installer, log:$log, deps_log:$deps_log, rc:$rc, ts:$ts}]' "$summary" > "$summary.tmp"
  mv "$summary.tmp" "$summary"
}

collect_repos_interactively() {
  echo "Provide GitHub repository URLs (https://...) or 'git clone https://...' lines, one per line."
  echo "Press Enter on an empty line to finish, or type 'quit' to exit."

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "quit" ]] && { echo "Exiting by request."; exit 0; }
    [[ -z "$line" ]] && break

    if normalized="$(normalize_repo_input "$line")"; then
      REPOS+=("$normalized")
    else
      warn "Skipping invalid input: $line"
    fi
  done
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if normalized="$(normalize_repo_input "$1")"; then
          REPOS+=("$normalized")
        else
          err "Invalid argument: $1"
          usage
          exit 1
        fi
        shift
        ;;
    esac
  done
}

# -----------------------------
# Preconditions
# -----------------------------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  err "Do not run this script as root."
  exit 1
fi

parse_args "$@"
if [[ ${#REPOS[@]} -eq 0 ]]; then
  collect_repos_interactively
fi
if [[ ${#REPOS[@]} -eq 0 ]]; then
  err "No repositories provided."
  exit 1
fi

write_status_files_init

if [[ "$DRY_RUN" -eq 0 ]]; then
  backup_files
else
  log "DRY RUN: skipping backups"
fi

if [[ ! -d "$VENV_DIR" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN: would create venv at $VENV_DIR"
  else
    log "Creating Python virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
else
  log "DRY RUN: would activate venv at $VENV_DIR"
fi

SUMMARY_JSON="$LOG_DIR/summary_$(timestamp).json"
printf '[]' > "$SUMMARY_JSON"

for repo in "${REPOS[@]}"; do
  echo
  echo "=============================================="
  echo "Processing repo: $repo"

  repo_name="$(basename "$repo" .git)"
  target_dir="$ALLOWED_ROOT/$repo_name"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN: would clone $repo into $target_dir"
    echo "$repo (dry-run)" >> "$STATUS_DIR/install_skipped.txt"
    continue
  fi

  if [[ -d "$target_dir/.git" ]]; then
    log "Repo already exists at $target_dir; pulling latest changes"
    (cd "$target_dir" && git pull --ff-only) || { warn "Failed to update $repo"; continue; }
  else
    git clone "$repo" "$target_dir" || { warn "Clone failed for $repo"; continue; }
  fi

  install_script="$target_dir/install.sh"
  if [[ ! -f "$install_script" ]]; then
    warn "No install.sh found in $target_dir — skipping"
    echo "$repo (no install.sh)" >> "$STATUS_DIR/install_skipped.txt"
    continue
  fi

  if ! is_under_allowed_root "$install_script"; then
    warn "Installer outside allowed root: $install_script"
    echo "Type override token to proceed: $OVERRIDE_OUTSIDE_TOKEN"
    read -r token
    if [[ "$token" != "$OVERRIDE_OUTSIDE_TOKEN" ]]; then
      warn "Skipped due to path policy"
      echo "$repo (outside allowed root)" >> "$STATUS_DIR/install_skipped.txt"
      continue
    fi
  fi

  preview_script_head "$install_script"

  if contains_dangerous_patterns "$install_script"; then
    warn "Dangerous patterns detected in $install_script"
    echo "Type confirmation token to continue: $FORCE_TOKEN"
    read -r token2
    if [[ "$token2" != "$FORCE_TOKEN" ]]; then
      warn "Refusing to run $install_script without confirmation"
      echo "$repo (dangerous pattern - not confirmed)" >> "$STATUS_DIR/install_skipped.txt"
      continue
    fi
  fi

  echo "Run now? [y = run, n = skip, p = pause & exit]"
  read -r resp
  if [[ "$resp" =~ ^[Pp]$ ]]; then
    log "Paused by user; exiting cleanly"
    exit 0
  elif [[ ! "$resp" =~ ^[Yy]$ ]]; then
    echo "$repo (user skipped)" >> "$STATUS_DIR/install_skipped.txt"
    continue
  fi

  basename_f="$(basename "$install_script")"
  log_file="$LOG_DIR/${repo_name}_${basename_f}.log"
  dep_log="$LOG_DIR/${repo_name}_${basename_f}_deps.log"

  install_python_deps "$target_dir" "$dep_log" || true
  install_node_deps "$target_dir" "$dep_log" || true

  log "Running $install_script"
  rc=0
  (bash "$install_script") > >(tee "$log_file") 2> >(tee -a "$log_file" >&2) || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "$repo" >> "$STATUS_DIR/install_completed.txt"
    log "Completed installer successfully"
  else
    echo "$repo (exit $rc)" >> "$STATUS_DIR/install_skipped.txt"
    warn "Installer failed with exit code $rc"
  fi

  if command -v jq >/dev/null 2>&1; then
    append_summary_json "$SUMMARY_JSON" "$repo" "$log_file" "$dep_log" "$rc"
  else
    warn "jq not installed; skipped summary JSON append"
  fi
done

echo
echo "All done."
echo "Logs: $LOG_DIR"
echo "Skipped list: $STATUS_DIR/install_skipped.txt"
echo "Completed list: $STATUS_DIR/install_completed.txt"
echo "Summary JSON: $SUMMARY_JSON"
