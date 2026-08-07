#!/usr/bin/env bash
set -euo pipefail

# Deploy the public dirwiz.app site to Cloudflare Pages production.
#
# Never upload the whole docs/ tree - it also holds internal notes
# (strategic-analysis.md, performance-loop.md, …). This script stages an
# explicit allowlist, then deploys with --branch main so the apex custom
# domain updates. Git's default branch is main; Pages production is main.
# Do not run bare `wrangler pages deploy` from a non-main branch and expect
# dirwiz.app to move.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${DIRWIZ_PAGES_PROJECT:-dirwiz}"
PRODUCTION_BRANCH="${DIRWIZ_PAGES_BRANCH:-main}"
DOCS="$ROOT/docs"

need() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "deploy-site: missing required file: $path" >&2
    exit 1
  fi
}

need "$DOCS/index.html"
need "$DOCS/404.html"
need "$DOCS/assets/dirwiz-logo.png"
need "$DOCS/assets/dirwiz-showcase.webp"
need "$DOCS/assets/dirwiz-social-preview.png"
need "$DOCS/assets/tab-search.webp"
need "$DOCS/assets/tab-dupes.webp"
need "$DOCS/assets/tab-insights.webp"

if ! command -v wrangler >/dev/null 2>&1; then
  echo "deploy-site: wrangler not found on PATH" >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dirwiz-pages-XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE/assets"
cp "$DOCS/index.html" "$DOCS/404.html" "$STAGE/"
cp "$DOCS/assets/dirwiz-logo.png" \
   "$DOCS/assets/dirwiz-showcase.webp" \
   "$DOCS/assets/dirwiz-social-preview.png" \
   "$DOCS/assets/tab-search.webp" \
   "$DOCS/assets/tab-dupes.webp" \
   "$DOCS/assets/tab-insights.webp" \
   "$STAGE/assets/"

# Fail closed if anything outside the allowlist slipped into the staging tree.
while IFS= read -r -d '' file; do
  rel="${file#"$STAGE"/}"
  case "$rel" in
    index.html|404.html|\
    assets/dirwiz-logo.png|assets/dirwiz-showcase.webp|assets/dirwiz-social-preview.png|\
    assets/tab-search.webp|assets/tab-dupes.webp|assets/tab-insights.webp)
      ;;
    *)
      echo "deploy-site: unexpected staged file: $rel" >&2
      exit 1
      ;;
  esac
done < <(find "$STAGE" -type f -print0)

echo "Staged allowlist:"
find "$STAGE" -type f | sort | while read -r file; do
  echo "  ${file#"$STAGE"/}"
done

echo "Deploying to Cloudflare Pages project '$PROJECT_NAME' (branch $PRODUCTION_BRANCH = production)…"
wrangler pages deploy "$STAGE" \
  --project-name "$PROJECT_NAME" \
  --branch "$PRODUCTION_BRANCH" \
  --commit-dirty=true

EXPECTED_VERSION="$(
  sed -n 's/.*Version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
    "$DOCS/index.html" | head -n 1
)"
if [[ -z "$EXPECTED_VERSION" ]]; then
  echo "deploy-site: could not parse Version from docs/index.html" >&2
  exit 1
fi

# Apex can lag a few seconds behind the deployment URL.
# Buffer the body first: `curl | grep -q` can SIGPIPE curl (exit 56) under `pipefail`
# when grep closes early on a match.
for _ in 1 2 3 4 5 6; do
  body="$(curl -fsSL "https://dirwiz.app/")"
  case "$body" in
    *"Version ${EXPECTED_VERSION}"*)
      echo "Verified https://dirwiz.app shows Version ${EXPECTED_VERSION}"
      exit 0
      ;;
  esac
  sleep 2
done

echo "deploy-site: warning: deploy finished but https://dirwiz.app does not yet show Version ${EXPECTED_VERSION}" >&2
echo "Check the production deployment in the Cloudflare dashboard." >&2
exit 1
