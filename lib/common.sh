# Shared helpers for promote.sh and rollback.sh: logging, argument parsing, tool checks, GitHub
# auth and the preflight that makes sure bundles are written from an up to date checkout.

VALID_ENVS=("dev" "staging" "production")

# Print an error and stop. Every failure aborts the whole run, like the original promote.sh, so
# nothing after the failing step (records, bundle, commit) happens.
die() {
  echo "  ! $*" >&2
  exit 1
}

is_valid_env() {
  [[ " ${VALID_ENVS[*]} " =~ " ${1} " ]]
}

# Split the arguments into flags and positionals. Sets DRY_RUN, SKIP_SLACK, DEBUG, DEBUG_CURL and
# POSITIONAL. Unknown flags are rejected so a typo like --dryrun never runs a real promotion.
parse_args() {
  DRY_RUN=false
  SKIP_SLACK=false
  SNAPSHOT=false
  DEBUG=false
  DEBUG_CURL=()
  POSITIONAL=()
  local arg
  for arg in "$@"; do
    case $arg in
      --dry-run) DRY_RUN=true ;;
      --skip-slack) SKIP_SLACK=true ;;
      --snapshot) SNAPSHOT=true ;;
      --debug)
        DEBUG=true
        DEBUG_CURL=("-v")
        ;;
      --*)
        echo "Error: unknown option $arg"
        return 1
        ;;
      *) POSITIONAL+=("$arg") ;;
    esac
  done
}

require_tools() {
  local missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# GitHub auth: prefer an explicit GPP_GITHUB_TOKEN, otherwise borrow the credential `gh` already
# holds. Nothing to export by hand and nothing to expire in a drawer.
github_auth() {
  GITHUB_TOKEN_FROM_GH=false
  if [ -z "${GPP_GITHUB_TOKEN:-}" ]; then
    GPP_GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
    GITHUB_TOKEN_FROM_GH=true
  fi
}

print_env_status() {
  echo "##### Environment Variables Status"
  echo "GPP_SLACK_WEBHOOK_URL: $([ -n "${GPP_SLACK_WEBHOOK_URL:-}" ] && echo "✓ Set" || echo "✗ Not set")"
  echo "GPP_SLACK_CHANNEL: $([ -n "${GPP_SLACK_CHANNEL:-}" ] && echo "✓ Set ($GPP_SLACK_CHANNEL)" || echo "✗ Not set (will use default: #gpp)")"
  if [ -n "${GPP_GITHUB_TOKEN:-}" ]; then
    echo "GPP_GITHUB_TOKEN: ✓ Set"
  else
    echo "GPP_GITHUB_TOKEN:  ✗ Not set, and \`gh auth token\` gave nothing. Run \`gh auth login\`."
    exit 1
  fi
  echo
}

# Who to record as created_by in the bundle. GPP_PROMOTER overrides; when the token came from
# `gh`, the GitHub login is the most useful name; otherwise fall back to the git identity.
resolve_promoter() {
  PROMOTER=${GPP_PROMOTER:-}
  if [ -z "$PROMOTER" ] && [ "${GITHUB_TOKEN_FROM_GH:-false}" = true ]; then
    PROMOTER=$(gh api user --jq .login 2>/dev/null || true)
  fi
  if [ -z "$PROMOTER" ]; then
    PROMOTER=$(git -C "$REPO_ROOT" config user.name 2>/dev/null || true)
  fi
  if [ -z "$PROMOTER" ]; then
    PROMOTER="unknown"
  fi
}

# The bundles are only trustworthy if they are written on top of the latest main, from a tree
# with no stray edits that would end up in the bundle commit.
repo_preflight() {
  local root=$1
  echo "##### Preflight of $root"
  local branch
  branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null) || die "$root is not a git checkout"
  if [ "$branch" != "main" ]; then
    die "$root is on branch '$branch'; bundles are only written from main"
  fi
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    git -C "$root" status --short >&2
    die "$root has uncommitted changes; commit or stash them first"
  fi
  if ! git -C "$root" pull --ff-only --quiet; then
    die "git pull --ff-only failed in $root"
  fi
  echo "  ✓ On main, clean and up to date"
  echo
}

utc_timestamp() {
  date -u "+%Y-%m-%d %H:%M:%S UTC"
}
