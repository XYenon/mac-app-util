#!/usr/bin/env bash

# mac-app-util - Manage Mac App launchers
# Copyright (c) 2023-2025 Hraban Luyat
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

PLUTIL="/usr/bin/plutil"

# Based on a hunch, nothing scientific.
COPYABLE_APP_PROPS=(
	"CFBundleDevelopmentRegion"
	"CFBundleDocumentTypes"
	"CFBundleGetInfoString"
	"CFBundleIconFile"
	"CFBundleIdentifier"
	"CFBundleInfoDictionaryVersion"
	"CFBundleName"
	"CFBundleShortVersionString"
	"CFBundleURLTypes"
	"NSAppleEventsUsageDescription"
	"NSAppleScriptEnabled"
	"NSDesktopFolderUsageDescription"
	"NSDocumentsFolderUsageDescription"
	"NSDownloadsFolderUsageDescription"
	"NSPrincipalClass"
	"NSRemovableVolumesUsageDescription"
	"NSServices"
	"UTExportedTypeDeclarations"
)

non_empty_env() {
	[[ -n ${!1-} ]]
}

DRY_RUN=0
if non_empty_env "DRY_RUN"; then
	DRY_RUN=1
fi

if non_empty_env "DEBUGSH"; then
	set -x
fi

rootp() {
	[[ ${USER-} == "root" ]]
}

escape_applescript_string() {
	# Escape for inclusion inside an AppleScript string literal.
	# This is separate from AppleScript's `quoted form of`, which is about escaping
	# for the shell layer.
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '%s' "$s"
}

print_cmd() {
	local -a q
	q=()
	local arg
	for arg in "$@"; do
		q+=("$(printf '%q' "$arg")")
	done
	printf '%s' "${q[*]}"
}

run() {
	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'exec: %s\n' "$(print_cmd "$@")"
		return 0
	fi
	"$@"
}

rm_rf() {
	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'rm -rf %q\n' "$1"
		return 0
	fi
	rm -rf -- "$1"
}

copy_file() {
	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'cp %q %q\n' "$1" "$2"
		return 0
	fi
	cp -- "$1" "$2"
}

with_temp_dir() {
	if [[ $DRY_RUN -eq 1 ]]; then
		"$@"
		return 0
	fi

	local dir
	dir="$(mktemp -d)"
	(
		cd "$dir"
		"$@"
	)
	rm_rf "$dir"
}

path_without_slash() {
	local p="$1"
	printf '%s' "${p%/}"
}

app_resources() {
	printf '%s/Contents/Resources/' "$(path_without_slash "$1")"
}

infoplist() {
	printf '%s/Contents/Info.plist' "$(path_without_slash "$1")"
}

app_p() {
	[[ -f "$(infoplist "$1")" ]]
}

realpath_portable() {
	# Best-effort absolute path, resolving directory symlinks. Works without GNU realpath.
	local p="$1"

	if [[ -d $p ]]; then
		(cd "$p" && pwd -P)
		return 0
	fi

	(cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
}

sync_icons() {
	local from="$1"
	local to="$2"

	local from_cnts to_cnts
	from_cnts="$(app_resources "$from")"
	to_cnts="$(app_resources "$to")"

	if [[ -d $from_cnts ]]; then
		run find "$to_cnts" -name '*.icns' -delete
		run rsync \
			--include '*.icns' \
			--exclude '*' \
			--recursive \
			--links \
			"$from_cnts" "$to_cnts"
	fi
}

copy_paths() {
	local from="$1"
	local to="$2"

	# shellcheck disable=SC2016
	local jqfilter='to_entries | [ .[] | select(.key as $item | $keys | index($item) >= 0) ] | from_entries'

	with_temp_dir _copy_paths_impl "$from" "$to" "$jqfilter"
}

_copy_paths_impl() {
	local from="$1"
	local to="$2"
	local jqfilter="$3"

	local keys_json
	keys_json="$(printf '%s\n' "${COPYABLE_APP_PROPS[@]}" | jq -R . | jq -s .)"

	copy_file "$from" "orig"
	copy_file "$to" "bare-wrapper"

	run "$PLUTIL" -convert json -- orig
	run "$PLUTIL" -convert json -- bare-wrapper

	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'exec: %s <orig >filtered\n' "$(print_cmd jq --argjson keys "$keys_json" "$jqfilter")"
		printf 'exec: %s >final\n' "$(print_cmd jq -s add bare-wrapper filtered)"
	else
		jq --argjson keys "$keys_json" "$jqfilter" <orig >filtered
		jq -s add bare-wrapper filtered >final
	fi
	run "$PLUTIL" -convert xml1 -- final

	copy_file final "$to"
}

mktrampoline_app() {
	local app="$1"
	local trampoline="$2"

	local cmd
	local app_escaped
	app_escaped="$(escape_applescript_string "$app")"
	cmd="do shell script \"open \" & quoted form of \"${app_escaped}\""

	run /usr/bin/osacompile -o "$trampoline" -e "$cmd"
	sync_icons "$app" "$trampoline"
	copy_paths "$(infoplist "$app")" "$(infoplist "$trampoline")"

	# Occasionally Finder/Launchpad shows blank/stock icons; touching seems to help.
	run touch "$trampoline"
}

mktrampoline_bin() {
	local bin="$1"
	local trampoline="$2"

	# For applescript not to wait on the binary you must background it and direct both pipes.
	local cmd
	local bin_escaped
	bin_escaped="$(escape_applescript_string "$bin")"
	cmd="do shell script (quoted form of \"${bin_escaped}\") & \" &> /dev/null &\""
	run /usr/bin/osacompile -o "$trampoline" -e "$cmd"
}

mktrampoline() {
	local from="$1"
	local to="$2"

	if [[ ! -e $from ]]; then
		printf 'No such file: %s\n' "$from" >&2
		exit 1
	fi

	# Normalize FROM early, since we later chdir into temp dirs.
	if [[ $from != /* ]]; then
		from="$PWD/$from"
	fi

	if [[ $to != /* ]]; then
		to="$PWD/$to"
	fi

	if [[ -d $from ]]; then
		if app_p "$from"; then
			mktrampoline_app "$(path_without_slash "$from")" "$(path_without_slash "$to")"
		else
			printf 'Path %s does not appear to be a Mac app (missing Info.plist)\n' "$from" >&2
			exit 1
		fi
	else
		mktrampoline_bin "$(realpath_portable "$from")" "$(path_without_slash "$to")"
	fi
}

sync_dock() {
	# dockutil doesn't like acting under sudo and will fall back to the original user.
	export SUDO_USER=""

	local -a dockutil_args
	dockutil_args=()
	if rootp; then
		dockutil_args+=(--allhomes)
	fi

	local -a apps
	apps=("$@")

	local persistents
	persistents="$(
		dockutil "${dockutil_args[@]}" -L |
			awk -F '\t' '/\/nix\/store/ && /persistentApps/ { print $1 }'
	)"

	local existing
	while IFS= read -r existing; do
		[[ -n $existing ]] || continue

		local app
		for app in "${apps[@]}"; do
			local base
			base="$(basename "$(path_without_slash "$app")")"
			base="${base%.app}"

			if [[ $base == "$existing" ]]; then
				run dockutil "${dockutil_args[@]}" --add "$(realpath_portable "$app")" --replacing "$existing"
				break
			fi
		done
	done <<<"$persistents"
}

symlinked_dir_p() {
	local d
	d="${1%/}"
	[[ -d $d && -L $d ]]
}

to_abs_dir() {
	local d="$1"
	if [[ $d != /* ]]; then
		d="$PWD/$d"
	fi
	printf '%s' "${d%/}/"
}

gather_apps() {
	local dir="$1"
	shopt -s nullglob
	local -a apps
	apps=("$dir"/*.app "$dir"/*/*.app)
	shopt -u nullglob
	if [[ ${#apps[@]} -gt 0 ]]; then
		printf '%s\n' "${apps[@]}"
	fi
}

sync_trampolines() {
	local from to
	from="$(to_abs_dir "$1")"
	to="$(to_abs_dir "$2")"

	rm_rf "$to"

	# Since 25.11 nix-darwin copies .app folders directly to /Applications. In
	# that scenario, trampolines only get in the way.
	if ! symlinked_dir_p "$from"; then
		return 0
	fi

	run mkdir -p "$to"

	local -a apps
	mapfile -t apps < <(gather_apps "$from")

	local app
	for app in "${apps[@]}"; do
		mktrampoline "$app" "${to}$(basename "$app")"
	done

	sync_dock "${apps[@]}"
}

print_usage() {
	cat <<'EOF'
Usage:

    mac-app-util mktrampoline FROM.app TO.app
    mac-app-util sync-dock Foo.app Bar.app ...
    mac-app-util sync-trampolines /my/nix/Applications /Applications/MyTrampolines/

mktrampline creates a "trampoline" application launcher that immediately
launches another application.

sync-dock updates persistent items in your dock if any of the given apps has the
same name. This can be used to programmatically keep pinned items in your dock
up to date with potential new versions of an app outside of the /Applications
directory, without having to check which one is pinned etc.

sync-trampolines is an all-in-1 solution that syncs an entire directory of *.app
files to another by creating a trampoline launcher for every app, deleting the
rest, and updating the dock.
EOF
}

main() {
	if [[ ${1-} == "-h" || ${1-} == "--help" ]]; then
		print_usage
		return 0
	fi

	case "${1-}" in
	mktrampoline)
		[[ $# -eq 3 ]] || {
			print_usage >&2
			return 1
		}
		shift
		mktrampoline "$1" "$2"
		;;
	sync-dock)
		shift
		[[ $# -ge 1 ]] || {
			print_usage >&2
			return 1
		}
		sync_dock "$@"
		;;
	sync-trampolines)
		[[ $# -eq 3 ]] || {
			print_usage >&2
			return 1
		}
		shift
		sync_trampolines "$1" "$2"
		;;
	*)
		print_usage >&2
		return 1
		;;
	esac
}

main "$@"
