#!/usr/bin/env bash
# rbw-env: print `export KEY=value` lines from a Bitwarden note retrieved via rbw,
# suitable for `eval` in a shell or a direnv .envrc.

set -euo pipefail

usage() {
	echo "usage: rbw-env [--name NAME] [--folder FOLDER]" >&2
}

name="${RBW_ENV_NAME:-}"
folder="${RBW_ENV_FOLDER:-}"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--name)
		[ "$#" -ge 2 ] || {
			usage
			exit 1
		}
		name="$2"
		shift 2
		;;
	--name=*)
		name="${1#--name=}"
		shift
		;;
	--folder)
		[ "$#" -ge 2 ] || {
			usage
			exit 1
		}
		folder="$2"
		shift 2
		;;
	--folder=*)
		folder="${1#--folder=}"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "rbw-env: unknown argument: $1" >&2
		usage
		exit 1
		;;
	esac
done

# Name fallback chain: argument/env -> git repository root -> current directory.
if [ -z "$name" ]; then
	root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	if [ -n "$root" ]; then
		name="${root##*/}"
	else
		name="${PWD##*/}"
	fi
fi

folder_args=()
if [ -n "$folder" ]; then
	folder_args=(--folder "$folder")
fi

if ! command -v rbw >/dev/null 2>&1; then
	echo "rbw-env: rbw is not available, skipping" >&2
	exit 0
fi

# rbw get can block forever when the rbw agent is unresponsive, which would
# freeze the shell (or direnv) evaluating this script. Bound the wait; set
# RBW_ENV_TIMEOUT=0 to disable the timeout.
timeout_duration="${RBW_ENV_TIMEOUT:-10}"
case "$timeout_duration" in
'' | *[!0-9]*) timeout_duration=10 ;;
esac

# rbw get does not start the agent itself: spawn it detached if the socket is
# missing, mirroring the socket path computed by rbw (see rbw's dirs.rs), and
# wait only for the socket to appear.
rbw_profile="rbw"
if [ -n "${RBW_PROFILE:-}" ]; then
	rbw_profile="rbw-$RBW_PROFILE"
fi
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
	rbw_socket="$XDG_RUNTIME_DIR/$rbw_profile/socket"
else
	rbw_socket="${TMPDIR:-/tmp}/$rbw_profile-$(id -u)/socket"
fi
if [ ! -e "$rbw_socket" ] && command -v rbw-agent >/dev/null 2>&1; then
	rbw-agent >/dev/null 2>&1 &
	socket_tries=0
	while [ ! -e "$rbw_socket" ] && [ "$socket_tries" -lt $((timeout_duration * 10)) ]; do
		sleep 0.1
		socket_tries=$((socket_tries + 1))
	done
fi

# Run rbw get with a bounded wait, so a stuck rbw-agent can never block the
# caller. rbw's output goes through a FIFO (nothing touches disk) and is read
# with a per-read timeout; when the timeout fires, the client is killed and
# its exit status (SIGTERM) tells the timeout apart from a genuine failure.
# No watchdog process is left behind, which matters for callers like bats
# that wait for every descendant process.
fifo_dir=""
if [ "$timeout_duration" -gt 0 ] && command -v mkfifo >/dev/null 2>&1; then
	fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/rbw-env.XXXXXXXX" 2>/dev/null)" || fifo_dir=""
	if [ -n "$fifo_dir" ]; then
		mkfifo "$fifo_dir/out" 2>/dev/null || fifo_dir=""
	fi
fi

rbw_status=0
timed_out=0
if [ -n "$fifo_dir" ]; then
	trap 'rm -rf "$fifo_dir" 2>/dev/null || :' EXIT
	rbw get "${folder_args[@]}" "$name" >"$fifo_dir/out" 2>/dev/null &
	rbw_pid=$!
	exec 9<"$fifo_dir/out"
	content=""
	while IFS= read -r -t "$timeout_duration" line <&9; do
		content+="$line"$'\n'
	done
	exec 9<&-
	killed=0
	if kill -0 "$rbw_pid" 2>/dev/null; then
		kill "$rbw_pid" 2>/dev/null || :
		killed=1
	fi
	wait "$rbw_pid" 2>/dev/null || rbw_status=$?
	if [ "$killed" -eq 1 ] && [ "$rbw_status" -eq 143 ]; then
		timed_out=1
	fi
	rm -rf "$fifo_dir"
	fifo_dir=""
else
	content="$(rbw get "${folder_args[@]}" "$name" 2>/dev/null)" || rbw_status=$?
fi

if [ "$timed_out" -eq 1 ]; then
	echo "rbw-env: rbw get timed out after ${timeout_duration}s, skipping" >&2
	exit 0
fi

if [ "$rbw_status" -ne 0 ]; then
	echo "rbw-env: could not retrieve item '$name' from rbw, skipping" >&2
	exit 0
fi

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

while IFS= read -r line || [ -n "$line" ]; do
	line="$(trim "${line%$'\r'}")"
	case "$line" in
	'' | \#*) continue ;;
	esac
	case "$line" in
	export\ *) line="$(trim "${line#export }")" ;;
	esac
	case "$line" in
	*=*)
		key="$(trim "${line%%=*}")"
		value="$(trim "${line#*=}")"
		case "$key" in
		"" | *[!A-Za-z0-9_]* | [!A-Za-z_]*)
			echo "rbw-env: skipping invalid variable name: $key" >&2
			continue
			;;
		esac
		case "$value" in
		\"*)
			value="${value#\"}"
			if [[ $value != *\"* ]]; then
				echo "rbw-env: skipping $key with unmatched double quote" >&2
				continue
			fi
			value="${value%%\"*}"
			;;
		\'*)
			value="${value#\'}"
			if [[ $value != *\'* ]]; then
				echo "rbw-env: skipping $key with unmatched single quote" >&2
				continue
			fi
			value="${value%%\'*}"
			;;
		*)
			value="$(trim "${value%%[[:space:]]#*}")"
			;;
		esac
		printf 'export %s=%q\n' "$key" "$value"
		;;
	*)
		echo "rbw-env: skipping line without '=': $line" >&2
		;;
	esac
done <<<"$content"
