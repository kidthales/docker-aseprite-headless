#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CLEAN_YML="$REPO_ROOT/.github/workflows/clean.yml"
ENTRYPOINT="$REPO_ROOT/entrypoint.sh"

# Extract the live exclude-tags regex from clean.yml
EXCLUDE_REGEX=$(sed -n "s/^[[:space:]]*exclude-tags:[[:space:]]*'\([^']*\)'.*/\1/p" "$CLEAN_YML")
if [ -z "$EXCLUDE_REGEX" ]; then
	printf 'FAIL: could not extract exclude-tags regex from %s\n' "$CLEAN_YML" >&2
	exit 1
fi

assert_tag_matches() {
	tag="$1"
	if ! printf '%s\n' "$tag" | grep -Eq "$EXCLUDE_REGEX"; then
		printf 'FAIL: expected exclude-tags regex to match tag %s\n' "$tag" >&2
		exit 1
	fi
}

assert_tag_rejected() {
	tag="$1"
	if printf '%s\n' "$tag" | grep -Eq "$EXCLUDE_REGEX"; then
		printf 'FAIL: expected exclude-tags regex to reject tag %s\n' "$tag" >&2
		exit 1
	fi
}

# Positive retention assertions
assert_tag_matches "main"
assert_tag_matches "latest"
assert_tag_matches "main-headless"
assert_tag_matches "main-headless-amd64"
assert_tag_matches "main-headless-arm64"
assert_tag_matches "v1.3.18.6-headless"
assert_tag_matches "v1.3.18.6-headless-amd64"
assert_tag_matches "v1.4.0-headless"

# Negative retention assertions (must not be excluded from pruning)
assert_tag_rejected ""
assert_tag_rejected "pr-69-headless"
assert_tag_rejected "25.10"
assert_tag_rejected "v1.3-headless"
assert_tag_rejected "v1.3.18.6"
assert_tag_rejected "main-foo"
assert_tag_rejected "nightly-main-headless"

# Entrypoint behavior and negative exit-code propagation tests
TMP_BIN=$(mktemp -d)
trap 'rm -rf "$TMP_BIN"' EXIT

cat > "$TMP_BIN/aseprite" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
	printf 'Aseprite 1.3.18.6-x64\n'
	exit 0
fi
printf 'aseprite mock: unsupported args: %s\n' "$*" >&2
exit 42
EOF
chmod +x "$TMP_BIN/aseprite"

# Positive: flag-first invocation forwards to aseprite
PATH="$TMP_BIN:$PATH" sh "$ENTRYPOINT" --version > /dev/null

# Positive: non-flag command executes directly without prepending aseprite
PATH="$TMP_BIN:$PATH" sh "$ENTRYPOINT" sh -c 'exit 0'

# Negative: flag-first failure propagates non-zero exit code from aseprite
set +e
PATH="$TMP_BIN:$PATH" sh "$ENTRYPOINT" --invalid-flag 2>/dev/null
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
	printf 'FAIL: expected entrypoint flag failure exit code 42, got %s\n' "$rc" >&2
	exit 1
fi

# Negative: explicit command failure propagates exact non-zero exit code
set +e
PATH="$TMP_BIN:$PATH" sh "$ENTRYPOINT" sh -c 'exit 17'
rc=$?
set -e
if [ "$rc" -ne 17 ]; then
	printf 'FAIL: expected entrypoint command failure exit code 17, got %s\n' "$rc" >&2
	exit 1
fi

# Negative: missing executable fails with non-zero exit code
set +e
PATH="$TMP_BIN:$PATH" sh "$ENTRYPOINT" nonexistent-command-xyz 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	printf 'FAIL: expected non-zero exit code for missing command\n' >&2
	exit 1
fi

# Dockerfile & CI workflow invariant checks (positive and negative assertions)
DOCKERFILE="$REPO_ROOT/Dockerfile"
LINT_YML="$REPO_ROOT/.github/workflows/lint.yml"
BASE_YML="$REPO_ROOT/.github/workflows/base.yml"

# shellcheck disable=SC2016
if ! grep -Fq 'git -C /opt/aseprite fetch --depth 1 origin "${aseprite_git_ref}"' "$DOCKERFILE"; then
	printf 'FAIL: Dockerfile must include commit-SHA git fetch fallback\n' >&2
	exit 1
fi

if ! grep -Fq 'ENV HOME=/tmp' "$DOCKERFILE"; then
	printf 'FAIL: Dockerfile must set ENV HOME=/tmp for non-root --user runs\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq -- '--mount=type=cache,target=/root/.ccache,id=ccache-${TARGETARCH}' "$DOCKERFILE"; then
	printf 'FAIL: Dockerfile must mount per-arch BuildKit ccache\n' >&2
	exit 1
fi

# Negative: third-party Trivy, cache, and buildkit-cache-dance actions must be SHA-pinned (never mutable @vX tags)
for wf in "$LINT_YML" "$BASE_YML"; do
	if grep -Eq 'uses:[[:space:]]*(aquasecurity/trivy-action|actions/cache|reproducible-containers/buildkit-cache-dance)@v' "$wf"; then
		printf 'FAIL: %s must pin third-party actions to commit SHAs, not mutable tags\n' "$wf" >&2
		exit 1
	fi
done

if ! grep -Eq 'uses:[[:space:]]*aquasecurity/trivy-action@[0-9a-f]{40}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must pin trivy-action to a 40-char commit SHA\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq '*.tags=${{ env.IMAGE_REF }}' "$LINT_YML" || ! grep -Fq 'image-ref: ${{ env.IMAGE_REF }}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must align bake *.tags and trivy image-ref via env.IMAGE_REF\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq '*.cache-to=type=gha,mode=max,scope=${{ matrix.arch }}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must configure GHA cache-to export\n' >&2
	exit 1
fi

if ! grep -Fq 'reproducible-containers/buildkit-cache-dance@' "$LINT_YML" || ! grep -Fq 'reproducible-containers/buildkit-cache-dance@' "$BASE_YML"; then
	printf 'FAIL: lint.yml and base.yml must persist BuildKit ccache mounts via buildkit-cache-dance\n' >&2
	exit 1
fi

printf 'PASS: workflow retention regex, entrypoint, Dockerfile, and CI invariant tests passed\n'
