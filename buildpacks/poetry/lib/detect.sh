#!/usr/bin/env bash

detect_poetry_lock() {
	local build_dir=$1
	[[ -f "$build_dir/poetry.lock" ]]
}

write_to_build_plan() {
	local build_plan=$1
	cat <<EOF >"$build_plan"
	[[provides]]
	name = ".venv"

	[[requires]]
	name = ".venv"

	[[requires]]
	name = "python"
EOF
}
