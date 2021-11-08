#!/usr/bin/env bash

detect_pdm_lock() {
	local build_dir=$1
	[[ -f "$build_dir/pdm.lock" ]]
}

write_to_build_plan() {
	local build_plan=$1
	cat <<EOF >"$build_plan"
	[[requires]]
	name = "python"
EOF
}
