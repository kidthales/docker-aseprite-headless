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

# Dockerfile & CI workflow invariant checks (positive, negative, and semantic assertions)
DOCKERFILE="$REPO_ROOT/Dockerfile"
LINT_YML="$REPO_ROOT/.github/workflows/lint.yml"
BASE_YML="$REPO_ROOT/.github/workflows/base.yml"

# Semantic test of the live Dockerfile git clone + commit-SHA fallback block
# shellcheck disable=SC2016
CLONE_SNIPPET=$(sed -n '/^RUN if ! git clone/,/^[[:space:]]*fi$/p' "$DOCKERFILE" | sed '1s/^RUN //; s|/opt/aseprite|"$CLONE_TARGET"|g')
if [ -z "$CLONE_SNIPPET" ]; then
	printf 'FAIL: could not extract git clone fallback block from %s\n' "$DOCKERFILE" >&2
	exit 1
fi

GIT_LOG="$TMP_BIN/git.log"
CLONE_TARGET="$TMP_BIN/aseprite-src"
cat > "$TMP_BIN/git" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GIT_LOG"
case "${1:-}" in
	clone)
		mkdir -p "$CLONE_TARGET"
		if [ "${MOCK_CLONE_FAIL:-0}" = "1" ]; then
			: > "$CLONE_TARGET/partial-clone-marker"
			exit 1
		fi
		mkdir -p "$CLONE_TARGET/.git"
		exit 0
		;;
	init)
		target="${2:?}"
		if [ -e "$target/partial-clone-marker" ]; then
			printf 'FAIL: partial clone directory was not cleaned before git init\n' >&2
			exit 99
		fi
		mkdir -p "$target/.git"
		exit 0
		;;
	-C)
		shift 2
		case "${1:-}" in
			fetch)
				if [ "${MOCK_FETCH_FAIL:-0}" = "1" ]; then
					exit 1
				fi
				exit 0
				;;
			remote|checkout|submodule)
				exit 0
				;;
		esac
		;;
esac
printf 'FAIL: unexpected mock git invocation: %s\n' "$*" >&2
exit 98
EOF
chmod +x "$TMP_BIN/git"

# Case A: branch/tag clone succeeds on primary path without invoking fallback fetch
: > "$GIT_LOG"
rm -rf "$CLONE_TARGET"
PATH="$TMP_BIN:$PATH" GIT_LOG="$GIT_LOG" CLONE_TARGET="$CLONE_TARGET" aseprite_git_ref="v1.3.18.6" MOCK_CLONE_FAIL=0 sh -ec "$CLONE_SNIPPET"
if grep -q 'fetch --depth 1 origin' "$GIT_LOG"; then
	printf 'FAIL: tag clone path should not invoke commit-SHA fallback fetch\n' >&2
	exit 1
fi

# Case B: commit-SHA clone fails, partial dir is cleaned, and fallback fetch/checkout/submodule sequence runs
: > "$GIT_LOG"
rm -rf "$CLONE_TARGET"
SHA_REF="0123456789abcdef0123456789abcdef01234567"
PATH="$TMP_BIN:$PATH" GIT_LOG="$GIT_LOG" CLONE_TARGET="$CLONE_TARGET" aseprite_git_ref="$SHA_REF" MOCK_CLONE_FAIL=1 sh -ec "$CLONE_SNIPPET"
for expected_cmd in \
	"init $CLONE_TARGET" \
	"-C $CLONE_TARGET remote add origin https://github.com/aseprite/aseprite.git" \
	"-C $CLONE_TARGET fetch --depth 1 origin $SHA_REF" \
	"-C $CLONE_TARGET checkout FETCH_HEAD" \
	"-C $CLONE_TARGET submodule update --init --recursive --depth 1"; do
	if ! grep -Fq -- "$expected_cmd" "$GIT_LOG"; then
		printf 'FAIL: commit-SHA fallback missing expected step: %s\n' "$expected_cmd" >&2
		exit 1
	fi
done

# Case C: negative - fetch failure in fallback propagates non-zero exit code
: > "$GIT_LOG"
rm -rf "$CLONE_TARGET"
set +e
PATH="$TMP_BIN:$PATH" GIT_LOG="$GIT_LOG" CLONE_TARGET="$CLONE_TARGET" aseprite_git_ref="$SHA_REF" MOCK_CLONE_FAIL=1 MOCK_FETCH_FAIL=1 sh -ec "$CLONE_SNIPPET" 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	printf 'FAIL: expected non-zero exit code when fallback git fetch fails\n' >&2
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

if ! grep -Fq 'CCACHE_DIR=/root/.ccache' "$DOCKERFILE"; then
	printf 'FAIL: Dockerfile must explicitly pin CCACHE_DIR=/root/.ccache\n' >&2
	exit 1
fi

if ! grep -Eq 'CCACHE_MAXSIZE=[0-9]+[GM]' "$DOCKERFILE"; then
	printf 'FAIL: Dockerfile must bound ccache size via CCACHE_MAXSIZE\n' >&2
	exit 1
fi

if ! grep -Fq 'ccache -z' "$DOCKERFILE" || ! grep -Fq 'ccache -s' "$DOCKERFILE"; then
	printf 'FAIL: Dockerfile must reset and report ccache stats to monitor hit rate\n' >&2
	exit 1
fi

# Negative: third-party Trivy, cache, buildkit-cache-dance, and setup-task actions must be SHA-pinned (never mutable @vX tags)
for wf in "$LINT_YML" "$BASE_YML"; do
	if grep -Eq 'uses:[[:space:]]*(aquasecurity/trivy-action|actions/cache(/restore|/save)?|reproducible-containers/buildkit-cache-dance|arduino/setup-task)@v' "$wf"; then
		printf 'FAIL: %s must pin third-party actions to commit SHAs, not mutable tags\n' "$wf" >&2
		exit 1
	fi
done

if ! grep -Eq 'uses:[[:space:]]*aquasecurity/trivy-action@[0-9a-f]{40}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must pin trivy-action to a 40-char commit SHA\n' >&2
	exit 1
fi

if ! grep -Eq 'uses:[[:space:]]*arduino/setup-task@[0-9a-f]{40}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must pin setup-task to a 40-char commit SHA\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq '*.tags=${{ env.IMAGE_REF }}' "$LINT_YML" || ! grep -Fq 'image-ref: ${{ env.IMAGE_REF }}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must align bake *.tags and trivy image-ref via env.IMAGE_REF\n' >&2
	exit 1
fi

if ! grep -Fq 'mirrors = ["mirror.gcr.io"]' "$LINT_YML" || ! grep -Fq 'mirrors = ["mirror.gcr.io"]' "$BASE_YML"; then
	printf 'FAIL: lint.yml and base.yml must configure mirror.gcr.io registry mirror for docker.io\n' >&2
	exit 1
fi

# Cache-budget & ref-hygiene invariants: PR lint.yml must be read-only for ccache & gha buildx cache
if grep -Eq 'uses:[[:space:]]*actions/cache@' "$LINT_YML"; then
	printf 'FAIL: lint.yml must use actions/cache/restore (read-only), not actions/cache save\n' >&2
	exit 1
fi

if ! grep -Eq 'uses:[[:space:]]*actions/cache/restore@[0-9a-f]{40}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must use SHA-pinned actions/cache/restore\n' >&2
	exit 1
fi

if ! grep -Fq 'skip-extraction: true' "$LINT_YML"; then
	printf 'FAIL: lint.yml must set skip-extraction: true on buildkit-cache-dance\n' >&2
	exit 1
fi

if grep -Fq '*.cache-to=' "$LINT_YML"; then
	printf 'FAIL: lint.yml must not write *.cache-to on PR builds (protects 10GB repo cache)\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq '*.cache-from=type=gha,scope=${{ matrix.arch }}' "$LINT_YML"; then
	printf 'FAIL: lint.yml must consume GHA cache-from\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if grep -Eq '^[[:space:]]*ccache-\$\{\{ matrix\.arch \}\}-[[:space:]]*$' "$LINT_YML" "$BASE_YML"; then
	printf 'FAIL: restore-keys must not fall back to bare ref-agnostic ccache-<arch>-\n' >&2
	exit 1
fi

if ! grep -Fq 'task test:smoke' "$LINT_YML"; then
	printf 'FAIL: lint.yml build-and-test should run task test:smoke (avoiding redundant test:unit)\n' >&2
	exit 1
fi

if [ "$(grep -c 'uses:[[:space:]]*docker/bake-action@' "$BASE_YML")" -ne 1 ]; then
	printf 'FAIL: base.yml must use a single docker/bake-action step to prevent config drift\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq "if: inputs.aseprite-git-ref == 'main' && github.ref == 'refs/heads/main'" "$BASE_YML"; then
	printf 'FAIL: base.yml must gate cache writes strictly to main\n' >&2
	exit 1
fi

if ! grep -Fq "inputs.aseprite-git-ref == 'main' && github.ref == 'refs/heads/main' && format('*.cache-to=type=gha,mode=max,scope={0}', matrix.arch)" "$BASE_YML"; then
	printf 'FAIL: base.yml must configure conditional GHA cache-to export strictly for main builds\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
if ! grep -Fq '/actions/caches/${id}' "$BASE_YML" || ! grep -Fq 'prune-ccache:' "$BASE_YML"; then
	printf 'FAIL: base.yml must prune older nightly ccache entries to protect the 10GB repo cache budget\n' >&2
	exit 1
fi

# Least-privilege permissions scoping: actions: write must not be granted workflow-wide in base.yml or batch.yml
BATCH_YML="$REPO_ROOT/.github/workflows/batch.yml"
for wf in "$BASE_YML" "$BATCH_YML"; do
	top_perms=$(sed -n '/^permissions:/,/^[a-zA-Z]/p' "$wf")
	if printf '%s\n' "$top_perms" | grep -q 'actions: write'; then
		printf 'FAIL: %s must not grant actions: write at workflow top level\n' "$wf" >&2
		exit 1
	fi
done
if ! sed -n '/^  prune-ccache:/,$p' "$BASE_YML" | grep -q 'actions: write'; then
	printf 'FAIL: base.yml must scope actions: write to the prune-ccache job\n' >&2
	exit 1
fi

# Semantic test of the live prune-ccache step in base.yml with mocked gh and jq
PRUNE_SNIPPET=$(awk '
	/^  prune-ccache:/ { in_job=1 }
	in_job && /run: \|/ { in_run=1; next }
	in_run {
		if (/^          /) {
			sub(/^          /, "")
			print
		} else if (/^$/) {
			print ""
		} else {
			exit
		}
	}
' "$BASE_YML")
if [ -z "$PRUNE_SNIPPET" ]; then
	printf 'FAIL: could not extract prune-ccache script from %s\n' "$BASE_YML" >&2
	exit 1
fi

GH_LOG="$TMP_BIN/gh.log"
cat > "$TMP_BIN/gh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "api" ] && [ "${2:-}" = "-X" ] && [ "${3:-}" = "DELETE" ]; then
	if [ "${MOCK_GH_DELETE_FAIL:-0}" = "1" ]; then
		exit 1
	fi
	exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "--paginate" ] && [ "${3:-}" = "--slurp" ]; then
	url="${4:-}"
	if [ "${MOCK_GH_LIST_FAIL:-0}" = "1" ]; then
		exit 1
	fi
	case "$url" in
		*"key=ccache-amd64-main-"*)
			printf '[{"actions_caches":[{"id":101,"created_at":"2026-11-17T01:00:00Z"},{"id":102,"created_at":"2026-11-16T01:00:00Z"},{"id":103,"created_at":"2026-11-15T01:00:00Z"}]}]\n'
			;;
		*"key=ccache-arm64-main-"*)
			printf '[{"actions_caches":[{"id":201,"created_at":"2026-11-17T01:00:00Z"}]}]\n'
			;;
		*)
			printf '[{"actions_caches":[{"id":301,"key":"buildkit-1","size_in_bytes":3000000000},{"id":302,"key":"buildkit-2","size_in_bytes":2500000000}]}]\n'
			;;
	esac
	exit 0
fi
printf 'FAIL: unexpected mock gh args: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$TMP_BIN/gh"

cat > "$TMP_BIN/jq" <<'EOF'
#!/bin/sh
set -eu
cat > /dev/null
if [ "${MOCK_JQ_FAIL:-0}" = "1" ]; then
	exit 1
fi
# Distinguish query kind from the most recent gh api list call in GH_LOG
last_url=$(tail -n 1 "$GH_LOG")
case "$last_url" in
	*"key=ccache-amd64-main-"*)
		printf '102\n103\n'
		;;
	*"key=ccache-arm64-main-"*)
		;;
	*)
		printf '302\n'
		;;
esac
EOF
chmod +x "$TMP_BIN/jq"

# Prune Case A (Positive): deletes older amd64 ccache entries (102, 103) and over-budget GHA entry (302), keeps newest (101, 201)
: > "$GH_LOG"
PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" REPO="kidthales/docker-aseprite-headless" bash -c "$PRUNE_SNIPPET"
for expected_del in \
	"api -X DELETE /repos/kidthales/docker-aseprite-headless/actions/caches/102" \
	"api -X DELETE /repos/kidthales/docker-aseprite-headless/actions/caches/103" \
	"api -X DELETE /repos/kidthales/docker-aseprite-headless/actions/caches/302"; do
	if ! grep -Fq -- "$expected_del" "$GH_LOG"; then
		printf 'FAIL: prune-ccache missing expected delete: %s\n' "$expected_del" >&2
		exit 1
	fi
done
for kept_id in 101 201 301; do
	if grep -Fq -- "/actions/caches/${kept_id}" "$GH_LOG"; then
		printf 'FAIL: prune-ccache must not delete newest/in-budget cache id %s\n' "$kept_id" >&2
		exit 1
	fi
done

# Prune Case B (Negative): gh api list failure emits ::warning:: and fails non-zero
: > "$GH_LOG"
set +e
warn_out=$(PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" REPO="kidthales/docker-aseprite-headless" MOCK_GH_LIST_FAIL=1 bash -c "$PRUNE_SNIPPET" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! printf '%s\n' "$warn_out" | grep -q '::warning::'; then
	printf 'FAIL: prune-ccache must emit ::warning:: and exit non-zero on list failure (rc=%s)\n' "$rc" >&2
	exit 1
fi

# Prune Case C (Negative): jq failure in pipe fails non-zero (pipefail)
: > "$GH_LOG"
set +e
PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" REPO="kidthales/docker-aseprite-headless" MOCK_JQ_FAIL=1 bash -c "$PRUNE_SNIPPET" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	printf 'FAIL: prune-ccache must exit non-zero when jq pipe fails\n' >&2
	exit 1
fi

# Prune Case D (Negative): gh api DELETE failure emits ::warning:: and fails non-zero
: > "$GH_LOG"
set +e
warn_out=$(PATH="$TMP_BIN:$PATH" GH_LOG="$GH_LOG" REPO="kidthales/docker-aseprite-headless" MOCK_GH_DELETE_FAIL=1 bash -c "$PRUNE_SNIPPET" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! printf '%s\n' "$warn_out" | grep -q '::warning::'; then
	printf 'FAIL: prune-ccache must emit ::warning:: and exit non-zero on delete failure (rc=%s)\n' "$rc" >&2
	exit 1
fi

if ! grep -Fq 'reproducible-containers/buildkit-cache-dance@' "$LINT_YML" || ! grep -Fq 'reproducible-containers/buildkit-cache-dance@' "$BASE_YML"; then
	printf 'FAIL: lint.yml and base.yml must persist BuildKit ccache mounts via buildkit-cache-dance\n' >&2
	exit 1
fi

printf 'PASS: workflow retention regex, entrypoint, Dockerfile, and CI invariant tests passed\n'
