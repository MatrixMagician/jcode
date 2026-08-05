#!/usr/bin/env bash
# Install the current release binary into the immutable version store,
# update the stable + current channel symlinks, and point the launcher at current.
#
# Paths after install:
# - ~/.jcode/builds/versions/<hash>/jcode (immutable)
# - ~/.jcode/builds/stable/jcode -> .../versions/<hash>/jcode
# - ~/.jcode/builds/current/jcode -> .../versions/<hash>/jcode
# - ~/.local/bin/jcode -> ~/.jcode/builds/current/jcode (launcher)
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

profile="${JCODE_RELEASE_PROFILE:-release-lto}"
if [[ "${1:-}" == "--fast" ]]; then
  profile="release"
  shift
fi

if [[ "$#" -gt 0 ]]; then
  echo "Usage: $0 [--fast]" >&2
  exit 1
fi

case "$profile" in
  release-lto)
    echo "Building with LTO (this takes a few minutes)..."
    ;;
  release)
    echo "Building fast release profile (no LTO)..."
    ;;
  *)
    echo "Unsupported profile: $profile (expected: release or release-lto)" >&2
    exit 1
    ;;
esac

# Resolve the identity BEFORE building, so the binary embeds the same commit
# that names its install directory.
#
# Without this, `jcode-build-meta/build.rs` deliberately does not watch
# `.git/HEAD` (watching it turns routine git activity into full-tree rebuilds),
# so an incremental build reuses whatever hash was baked in last time. The
# install then lands in `versions/<new-hash>/` while `jcode --version` still
# reports the old one, which makes "did my change actually ship?" unanswerable.
# JCODE_BUILD_GIT_* are declared `rerun-if-env-changed`, so passing them forces
# exactly the metadata refresh we want and nothing more.
#
# Deliberately NOT setting JCODE_RELEASE_BUILD: that flips the version string
# from `-dev` to a bare release and marks the binary as a release build, which
# is a different claim than "installed from a local source tree".
short_hash=""
git_date=""
git_dirty="0"
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  short_hash="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true)"
  git_date="$(git -C "$repo_root" log -1 --format=%ci 2>/dev/null || true)"
  if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null || true)" ]]; then
    git_dirty="1"
  fi
fi

# Directory name keeps the historical `<hash>-dirty` suffix; the embedded hash
# stays bare because build.rs renders dirtiness separately as ", dirty".
hash="$short_hash"
if [[ -n "$hash" ]] && [[ "$git_dirty" == "1" ]]; then
  hash="${hash}-dirty"
fi

if [[ -z "$hash" ]]; then
  hash="$(date +%Y%m%d%H%M%S)"
fi

JCODE_BUILD_GIT_HASH="$short_hash" \
JCODE_BUILD_GIT_DATE="$git_date" \
JCODE_BUILD_GIT_DIRTY="$git_dirty" \
  cargo build --profile "$profile" --manifest-path "$repo_root/Cargo.toml"
bin="$repo_root/target/$profile/jcode"

if [[ ! -x "$bin" ]]; then
  echo "Release binary not found: $bin" >&2
  exit 1
fi

# The install dir is named after this commit, so the binary must agree. If it
# does not, the build script silently reused stale metadata and every later
# "which build am I running?" check would lie.
if [[ -n "$short_hash" ]]; then
  embedded="$("$bin" --version 2>/dev/null || true)"
  if [[ "$embedded" != *"$short_hash"* ]]; then
    echo "Built binary reports '$embedded', which does not contain the expected commit '$short_hash'." >&2
    echo "Refusing to install a binary that misreports its own identity." >&2
    exit 1
  fi
fi

# Install versioned binary into ~/.jcode/builds/versions/<hash>/
builds_dir="$HOME/.jcode/builds"
version_dir="$builds_dir/versions/$hash"
mkdir -p "$version_dir"
install -m 755 "$bin" "$version_dir/jcode"

# Update stable symlink
stable_dir="$builds_dir/stable"
mkdir -p "$stable_dir"
ln -sfn "$version_dir/jcode" "$stable_dir/jcode"

# Update stable-version marker
printf '%s\n' "$hash" > "$builds_dir/stable-version"

# Update current symlink + marker
current_dir="$builds_dir/current"
mkdir -p "$current_dir"
ln -sfn "$version_dir/jcode" "$current_dir/jcode"
printf '%s\n' "$hash" > "$builds_dir/current-version"

# Update launcher path to current channel
install_dir="${JCODE_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$install_dir"
ln -sfn "$current_dir/jcode" "$install_dir/jcode"

echo "Installed: $version_dir/jcode"
echo "Updated stable symlink: $stable_dir/jcode -> $version_dir/jcode"
echo "Updated current symlink: $current_dir/jcode -> $version_dir/jcode"
echo "Updated launcher symlink: $install_dir/jcode -> $current_dir/jcode"

# Configure supported desktop launch hotkeys as part of installation. This is
# idempotent and best-effort because headless installs may not expose a desktop
# session; the first interactive launch retries automatically.
case "$(uname -s)" in
  Darwin|Linux)
    if "$install_dir/jcode" setup-hotkey </dev/null >/dev/null 2>&1; then
      echo "Configured system-wide jcode launch hotkeys (when supported)."
    fi
    ;;
esac

# Gracefully reload any running background server onto the binary we just
# installed (issue #291). `server reload` only reloads when the running daemon
# is genuinely older, hands live headless/swarm sessions to the new process, and
# is a no-op when no server is running, so it is safe to call unconditionally.
if [ "${JCODE_SKIP_SERVER_RELOAD:-}" != "1" ]; then
  if "$install_dir/jcode" server reload </dev/null >/dev/null 2>&1; then
    echo "Reloaded the running jcode server onto $hash (if one was active)."
  fi
fi

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$install_dir"; then
  echo ""
  echo "Tip: add $install_dir to PATH if needed."
fi

# Ensure the launcher dir is on PATH for bash, zsh and fish in future shells.
# shellcheck source=scripts/lib/configure_path.sh
. "$(dirname "$0")/lib/configure_path.sh"
jcode_configure_path "$install_dir"
