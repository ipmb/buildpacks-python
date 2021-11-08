#!/usr/bin/env bash

set -e

# shellcheck disable=SC2128
bp_dir=$(
	cd "$(dirname "$BASH_SOURCE")"
	cd ..
	pwd
)

# shellcheck source=/dev/null
source "$bp_dir/lib/utils/env.sh"
# shellcheck source=/dev/null
source "$bp_dir/lib/utils/json.sh"
# shellcheck source=/dev/null
source "$bp_dir/lib/utils/log.sh"
# shellcheck source=/dev/null
source "$bp_dir/lib/utils/toml.sh"

# fail_multiple_lockfiles() {
# 	local build_dir=$1
# 	local has_modern_lockfile=false
# 	if [[ -f "$build_dir/package-lock.json" || -f "$build_dir/yarn.lock" ]]; then
# 		has_modern_lockfile=true
# 	fi

# 	if [[ -f "$build_dir/package-lock.json" && -f "$build_dir/yarn.lock" ]]; then
# 		error "Build failed because two different lockfiles were detected: package-lock.json and yarn.lock"
# 		exit 1
# 	fi

# 	if [[ $has_modern_lockfile && -f "$build_dir/npm-shrinkwrap.json" ]]; then
# 		error "Build failed because multiple lockfiles were detected"
# 		exit 1
# 	fi
# }

clear_cache_on_stack_change() {
	local layers_dir=$1

	if [[ -f "${layers_dir}/store.toml" ]]; then
		local last_stack
		# shellcheck disable=SC2002
		last_stack=$(cat "${layers_dir}/store.toml" | grep last_stack | xargs | cut -d " " -f3)

		if [[ "$CNB_STACK_ID" != "$last_stack" ]]; then
			info "Deleting cache because stack changed from \"$last_stack\" to \"$CNB_STACK_ID\""
			rm -rf "${layers_dir:?}"/*
		fi
	fi
}


install_or_reuse_poetry() {
	local layer_dir=$1
	local build_dir=$2

	local engine_poetry
	local poetry_version

	engine_poetry=$(toml_get_key_from_tool_heroku "$build_dir/pyproject.toml" "engines.poetry")
	poetry_version=${engine_poetry:-'1.*'}
	status "Installing poetry"
	if [[ $poetry_version == $(toml_get_key_from_metadata "${layer_dir}.toml" "version") ]]; then
		info "Reusing poetry==${poetry_version}"
	else
		info "Installing poetry==${poetry_version}"

		mkdir -p "$layer_dir"
		rm -rf "${layer_dir:?}"/*
		mkdir -p "$layer_dir/bin"
		# If we could install a stand-alone binary of poetry we would
		# Shiv is the next best thing. It creates a stand-alone executable zip file
		# so poetry can run without polluting the app's PYTHONPATH
		shiv_dir=$(mktemp -d)
		export PIP_QUIET="1"
		pip install --disable-pip-version-check --no-cache-dir --target "$shiv_dir" shiv==0.5.2
		PYTHONPATH="$shiv_dir" \
		"$shiv_dir/bin/shiv" --python "$(command -v python)" \
			--console-script poetry  \
			--output-file "$layer_dir/bin/poetry" \
			poetry=="${poetry_version}"
		unset PIP_QUIET
		info "$(poetry --version)"
	fi
	echo -e "[types]\ncache = true" >"${layer_dir}.toml"

	{
		echo "build = true"
		echo "launch = true"
		echo -e "[metadata]\nversion = \"$poetry_version\""
	} >>"${layer_dir}.toml"

	mkdir -p "${layer_dir}/env"
	echo -n "false" > "${layer_dir}/env/POETRY_VIRTUALENVS_CREATE"
}

detect_package_lock() {
	local build_dir=$1

	[[ -f "$build_dir/package-lock.json" ]]
}

run_prebuild() {
	local build_dir=$1
	local heroku_prebuild_script

	heroku_prebuild_script=$(toml_get_key_from_tool_heroku "$build_dir/pyproject.toml" "prebuild")

	if [[ $heroku_prebuild_script ]]; then
		eval $heroku_prebuild_script
	fi
}

install_pypackages() {
	local build_dir=$1
	local layer_dir=$2

	info "Installing Python packages from ./poetry.lock"
	
	# Poetry needs a virtualenv to install the packages into the layer
	python -m venv --system-site-packages $layer_dir
	export POETRY_VIRTUALENVS_CREATE=false
	# force poetry to install into the virtualenv
	$layer_dir/bin/python $(command -v poetry) install --no-interaction --no-dev
}

write_to_store_toml() {
	local layers_dir=$1

	if [[ ! -f "${layers_dir}/store.toml" ]]; then
		touch "${layers_dir}/store.toml"
		cat <<TOML >"${layers_dir}/store.toml"
[metadata]
last_stack = "$CNB_STACK_ID"
TOML
	fi
}

clear_cache_on_python_version_change() {
	local layers_dir=$1
	local curr_python_version

	curr_python_version="$(python --version | cut -f2 -d' ')"
	if [[ -n "${PREV_PYTHON_VERSION:-}" ]]; then
		if [[ "$curr_python_version" != "$PREV_PYTHON_VERSION" ]]; then
			info "Deleting cache because Python version changed from \"$PREV_PYTHON_VERSION\" to \"$curr_python_version\""
			rm -rf "${layers_dir:?}"/*
		fi
	fi
}

install_or_reuse_pypackages() {
	local build_dir=$1
	local layer_dir=$2
	local local_lock_checksum
	local cached_lock_checksum

	touch "$layer_dir.toml"
	mkdir -p "${layer_dir}"

	local_lock_checksum=$(sha256sum "$build_dir/poetry.lock" | cut -d " " -f 1)
	cached_lock_checksum=$(yj -t <"${layer_dir}.toml" | jq -r ".metadata.poetry_lock_checksum")

	if [[ "$local_lock_checksum" == "$cached_lock_checksum" ]]; then
		info "Reusing Python packages"
	else
		install_pypackages "$build_dir" "$layer_dir"
	fi
	echo -e "[types]\ncache = true" >"${layer_dir}.toml"

	{
		echo "build = true"
		echo "launch = true"
		echo -e "[metadata]\npoetry_lock_checksum = \"$local_lock_checksum\""
	} >>"${layer_dir}.toml"

	set_python_path "$layer_dir" build
	set_python_path "$layer_dir" launch
}

set_python_path() {
	local layer_dir=$1
	local lifecycle=$2

	pymajorminor=$(python -c "import sys; print('.'.join(map(str, sys.version_info[:2])))")
	mkdir -p "$layer_dir/env.build" "$layer_dir/env.launch"
	echo -n "${layer_dir}/lib/python${pymajorminor}/site-packages" > "${layer_dir}/env.${lifecycle}/PYTHONPATH.prepend"
	echo -n ":" > "${layer_dir}/env.${lifecycle}/PYTHONPATH.delim"
}

run_build() {
	local build_dir=$1
	local heroku_prebuild_script

	heroku_postbuild_script=$(toml_get_key_from_tool_heroku "$build_dir/pyproject.toml" "postbuild")

	if [[ $heroku_prebuild_script ]]; then
		eval $heroku_prebuild_script
	fi
}
