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

if ! content="$(rbw get "${folder_args[@]}" "$name" 2>/dev/null)"; then
	echo "rbw-env: could not retrieve item '$name' from rbw, skipping" >&2
	exit 0
fi

while IFS= read -r line || [ -n "$line" ]; do
	line="${line%$'\r'}"
	case "$line" in
	export\ *) line="${line#export }" ;;
	esac
	if [ -z "$line" ]; then
		continue
	fi
	case "$line" in
	*=*)
		key="${line%%=*}"
		value="${line#*=}"
		if [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
			printf 'export %s=%q\n' "$key" "$value"
		else
			echo "rbw-env: skipping invalid variable name: $key" >&2
		fi
		;;
	*)
		echo "rbw-env: skipping line without '=': $line" >&2
		;;
	esac
done <<<"$content"
