#!/usr/bin/env bash

bats_require_minimum_version 1.5.0

setup() {
	TESTDIR="$BATS_RUN_TMPDIR/rbw-env-$$"
	mkdir -p "$TESTDIR/bin" "$TESTDIR/runtime"
	RECORD="$TESTDIR/rbw-args"
	export TESTDIR RECORD

	# Mock rbw as an exported bash function: no external dependencies needed.
	# Behaviour is driven by the MOCK_* variables.
	# shellcheck disable=SC2329  # invoked indirectly, in the script's subprocess
	rbw() {
		printf '%s\n' "$*" >>"$RECORD"
		if [[ ${MOCK_FAIL:-} == "missing" ]]; then
			echo "Error: item not found" >&2
			return 1
		fi
		if [[ ${MOCK_HANG:-} == 1 ]]; then
			exec sleep 30
		fi
		cat "$TESTDIR/item" 2>/dev/null
	}
	export -f rbw

	# Isolate the agent state: tests must not depend on a rbw-agent running
	# (or not) on the host. A mock agent records its spawn in $SENTINEL and
	# "starts" by creating the socket.
	unset RBW_PROFILE
	SENTINEL="$TESTDIR/agent-spawned"
	export SENTINEL
	cat >"$TESTDIR/bin/rbw-agent" <<MOCK
#!/usr/bin/env bash
touch "\$SENTINEL"
mkdir -p "$TESTDIR/runtime/rbw"
touch "$TESTDIR/runtime/rbw/socket"
MOCK
	chmod +x "$TESTDIR/bin/rbw-agent"
	export PATH="$TESTDIR/bin:$PATH"
	export XDG_RUNTIME_DIR="$TESTDIR/runtime"
}

teardown() {
	unset -f rbw
	rm -rf "$TESTDIR"
}

run_script() {
	bash "$BATS_TEST_DIRNAME/rbw-env.sh" "$@"
}

@test "prints export lines that eval to the original values" {
	foo_orig='hello world'
	bar_orig="\$HOME'tick'"
	printf 'FOO=%s\nBAR=%s\n' "$foo_orig" "$bar_orig" >"$TESTDIR/item"
	eval "$(run_script --name test-item)"
	[ "$FOO" = "$foo_orig" ]
	[ "$BAR" = "$bar_orig" ]
}

@test "strips surrounding quotes from values" {
	printf '%s\n' 'A="https://aigw.cern.ch"' "B='hello world'" >"$TESTDIR/item"
	eval "$(run_script --name test-item)"
	[ "$A" = "https://aigw.cern.ch" ]
	[ "$B" = "hello world" ]
}

@test "skips comments and strips inline comments" {
	printf '%s\n' '# full-line comment' '  # indented comment' 'A=value # inline' 'B="keep # hash"' 'C=#literal' >"$TESTDIR/item"
	eval "$(run_script --name test-item)"
	[ "$A" = "value" ]
	[ "$B" = "keep # hash" ]
	[ "$C" = "#literal" ]
	[ -z "${full_line_comment+x}" ]
}

@test "trims whitespace around keys and values" {
	printf '%s\n' '  export  A = "x"  ' 'B = y' >"$TESTDIR/item"
	eval "$(run_script --name test-item)"
	[ "$A" = "x" ]
	[ "$B" = "y" ]
}

@test "skips unmatched quoted values" {
	printf 'A="unterminated\n' >"$TESTDIR/item"
	run --separate-stderr run_script --name test-item
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ $stderr == *"skipping A with unmatched double quote"* ]]
}

@test "prints export lines with safely quoted values" {
	printf 'FOO=hello world\n' >"$TESTDIR/item"
	run run_script --name test-item
	[ "$status" -eq 0 ]
	[ "$output" = 'export FOO=hello\ world' ]
}

@test "strips the export prefix and skips invalid lines" {
	printf 'export GOOD=1\nplain line\nBAD-NAME=2\n\nOK=yes\n' >"$TESTDIR/item"
	run --separate-stderr run_script --name test-item
	[ "$status" -eq 0 ]
	[ "$output" = $'export GOOD=1\nexport OK=yes' ]
	[[ $stderr == *"skipping line without '='"* ]]
	[[ $stderr == *"skipping invalid variable name: BAD-NAME"* ]]
}

@test "passes --name and --folder to rbw" {
	: >"$TESTDIR/item"
	run run_script --name item --folder "My Folder"
	[ "$status" -eq 0 ]
	[ "$(cat "$RECORD")" = "get --folder My Folder item" ]
}

@test "uses RBW_ENV_NAME and RBW_ENV_FOLDER" {
	: >"$TESTDIR/item"
	RBW_ENV_NAME="env-item" RBW_ENV_FOLDER="Env Folder" run run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$RECORD")" = "get --folder Env Folder env-item" ]
}

@test "command line --name overrides RBW_ENV_NAME" {
	: >"$TESTDIR/item"
	RBW_ENV_NAME="env-item" run run_script --name "cli-item"
	[ "$status" -eq 0 ]
	[ "$(cat "$RECORD")" = "get cli-item" ]
}

@test "exits with an error on unknown arguments" {
	run run_script --bogus
	[ "$status" -eq 1 ]
	[[ $output == *"unknown argument: --bogus"* ]]
	[[ $output == *"usage: rbw-env"* ]]
}

@test "falls back to the git repository root name" {
	: >"$TESTDIR/item"
	git init -q "$TESTDIR/myrepo"
	cd "$TESTDIR/myrepo" || return 1
	run run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$RECORD")" = "get myrepo" ]
}

@test "falls back to the current directory name outside a git repo" {
	: >"$TESTDIR/item"
	cd "$TESTDIR" || return 1
	run run_script
	[ "$status" -eq 0 ]
	[ "$(cat "$RECORD")" = "get rbw-env-$$" ]
}

@test "fails gracefully when rbw is not available" {
	bin="$TESTDIR/bin"
	mkdir -p "$bin"
	ln -s "$(command -v bash)" "$bin/bash"
	run bash -c 'unset -f rbw; PATH="$1" exec bash "$2" --name test-item' _ "$bin" "$BATS_TEST_DIRNAME/rbw-env.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"rbw is not available"* ]]
}

@test "fails gracefully when the item is not found" {
	MOCK_FAIL=missing run run_script --name missing-item
	[ "$status" -eq 0 ]
	[[ $output == *"could not retrieve item 'missing-item'"* ]]
}

@test "gives up when rbw hangs and the timeout expires" {
	MOCK_HANG=1 RBW_ENV_TIMEOUT=1 run run_script --name test-item
	[ "$status" -eq 0 ]
	[[ $output == *"timed out after 1s"* ]]
}

@test "retrieves normally when the timeout is long enough" {
	printf 'FOO=1\n' >"$TESTDIR/item"
	RBW_ENV_TIMEOUT=30 run run_script --name test-item
	[ "$status" -eq 0 ]
	[ "$output" = 'export FOO=1' ]
}

@test "spawns rbw-agent when the socket is missing" {
	run run_script --name test-item
	[ "$status" -eq 0 ]
	[ -e "$SENTINEL" ]
	[ -e "$TESTDIR/runtime/rbw/socket" ]
}

@test "does not spawn rbw-agent when the socket already exists" {
	mkdir -p "$TESTDIR/runtime/rbw"
	touch "$TESTDIR/runtime/rbw/socket"
	run run_script --name test-item
	[ "$status" -eq 0 ]
	[ ! -e "$SENTINEL" ]
}
