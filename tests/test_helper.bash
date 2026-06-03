# tests/test_helper.bash — common bats setup, sourced from every *.bats file.
#
# Each test:
#   - gets a fresh $XDG_CACHE_HOME under $BATS_TEST_TMPDIR (auto-cleaned)
#   - has $PLUGIN_ROOT and $LIB / $BIN paths set
#   - has the `tests/mocks/` PATH-prepended for tmux/claude stubs

# Resolve plugin root from test file location.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
LIB="$PLUGIN_ROOT/lib"
BIN="$PLUGIN_ROOT/bin"
FIXTURES="$TEST_DIR/fixtures"
MOCKS="$TEST_DIR/mocks"

export PLUGIN_ROOT LIB BIN FIXTURES MOCKS

# Per-test isolation.
#
# BATS_TEST_TMPDIR was added in bats-core 1.5; on older bats (Ubuntu 22.04
# ships 1.2.1) we synthesize an equivalent under $BATS_TMPDIR or /tmp.
setup_isolated_cache() {
  if [ -z "${BATS_TEST_TMPDIR:-}" ]; then
    BATS_TEST_TMPDIR="${BATS_TMPDIR:-/tmp}/tca-bats-$$-${BATS_TEST_NUMBER:-rand-$RANDOM}"
    mkdir -p "$BATS_TEST_TMPDIR"
    export BATS_TEST_TMPDIR
  fi
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  mkdir -p "$XDG_CACHE_HOME"
}

# Prepend mocks dir so `tmux`/`claude` invocations hit our stubs.
use_mocks() {
  export PATH="$MOCKS:$PATH"
}

# Optional: load bats-support / bats-assert if BATS_LIB_PATH is set and
# the libs are present. Tolerate absence — we ship our own shim assertions
# below as a fallback, so tests run on bare bats-core too.
if declare -F bats_load_library >/dev/null 2>&1; then
  if [ -n "${BATS_LIB_PATH:-}" ]; then
    if [ -d "${BATS_LIB_PATH%%:*}/bats-support" ]; then
      bats_load_library bats-support || true
    fi
    if [ -d "${BATS_LIB_PATH%%:*}/bats-assert" ]; then
      bats_load_library bats-assert || true
    fi
  fi
fi

# Minimal shim assertions when bats-assert isn't loaded. These cover the
# subset we actually use.
if ! type assert_equal >/dev/null 2>&1; then
  assert_equal() {
    local actual="$1" expected="$2"
    if [ "$actual" != "$expected" ]; then
      echo "expected: '$expected'"
      echo "actual:   '$actual'"
      return 1
    fi
  }
fi

if ! type assert_success >/dev/null 2>&1; then
  assert_success() {
    if [ "$status" -ne 0 ]; then
      echo "command failed (status=$status)"
      echo "output: $output"
      return 1
    fi
  }
fi

if ! type assert_failure >/dev/null 2>&1; then
  assert_failure() {
    if [ "$status" -eq 0 ]; then
      echo "command unexpectedly succeeded"
      echo "output: $output"
      return 1
    fi
  }
fi

if ! type assert_output >/dev/null 2>&1; then
  assert_output() {
    if [ "$1" = "--partial" ]; then
      shift
      case "$output" in
        *"$1"*) return 0 ;;
      esac
      echo "expected output to contain: '$1'"
      echo "actual output: '$output'"
      return 1
    fi
    if [ "$output" != "$1" ]; then
      echo "expected: '$1'"
      echo "actual:   '$output'"
      return 1
    fi
  }
fi
