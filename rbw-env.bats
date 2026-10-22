#!/usr/bin/env bash

bats_require_minimum_version 1.5.0

setup() {
	TESTDIR="$BATS_RUN_TMPDIR/rbw-env-$$"
	mkdir -p "$TESTDIR"
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
		cat "$TESTDIR/item" 2>/dev/null
	}
	export -f rbw
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
