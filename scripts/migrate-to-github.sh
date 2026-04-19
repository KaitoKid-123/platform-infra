#!/usr/bin/env bash
# =============================================================================
# migrate-to-github.sh
# Migrate repos from Gitea to GitHub
# NOTE: This script is kept for historical reference. Migration is complete.
#       Gitea resources have been removed; platform now uses GitHub exclusively.
# =============================================================================

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-KaitoKid-123}"

echo "=== Gitea → GitHub Migration (Completed) ==="
echo "GitHub User: $GITHUB_USER"
echo ""
echo "Migration status: COMPLETE"
echo "  - platform-infra: https://github.com/$GITHUB_USER/platform-infra"
echo "  - platform-dags:  https://github.com/$GITHUB_USER/platform-dags"
echo "  - finance-app:    https://github.com/$GITHUB_USER/finance-app"
echo ""
echo "Gitea resources have been removed from the platform."
echo "Use bootstrap-cluster.sh for fresh cluster setup."
echo "GitHub User: $GITHUB_USER"
echo ""

# Step 1: Create GitHub repos (manual - you need to do this)
echo "STEP 1: Create repos on GitHub"
echo "Go to: https://github.com/new"
echo "Create these repos (public or private):"
echo "  - $GITHUB_USER/platform-infra"
echo "  - $GITHUB_USER/platform-dags"
echo "  - $GITHUB_USER/finance-app"
echo ""
read -p "Press Enter after creating repos..."

# Step 2: Update remote URLs
echo ""
echo "STEP 2: Updating git remotes..."

update_remote() {
  local repo_dir="$1"
  local github_repo="$2"
  local current_remote

  cd "$repo_dir"
  current_remote=$(git remote get-url origin 2>/dev/null || echo "none")
  echo "  $repo_dir: $current_remote"

  # Add GitHub as new remote
  git remote add github "https://github.com/$GITHUB_USER/$github_repo.git" 2>/dev/null || true

  # Push to GitHub
  echo "  Pushing to GitHub..."
  git push github main --force 2>/dev/null || git push github main 2>/dev/null || echo "  WARNING: Push may have failed - check GitHub repos"
}

update_remote "/home/khang/Data-Platform/platform-infra" "platform-infra"
update_remote "/home/khang/Data-Platform/platform-dags" "platform-dags"
update_remote "/home/khang/Data-Platform/team-finance/finance-app" "finance-app"

echo ""
echo "Migration artifact preserved for documentation purposes."
