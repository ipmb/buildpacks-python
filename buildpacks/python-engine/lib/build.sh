#!/usr/bin/env bash

set -e

# shellcheck disable=SC2128
bp_dir=$(
	cd "$(dirname "$BASH_SOURCE")" || exit
	cd ..
	pwd
)

# shellcheck source=/dev/null
source "$bp_dir/lib/utils/log.sh"
# shellcheck source=/dev/null
source "$bp_dir/lib/utils/toml.sh"

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

set_up_environment() {
	local layer_dir=$1
	local node_env=${NODE_ENV:-production}

	mkdir -p "${layer_dir}/env.build"

	# if [[ ! -s "${layer_dir}/env.build/NODE_ENV.override" ]]; then
	# 	echo -e "$node_env\c" >>"${layer_dir}/env.build/NODE_ENV.override"
	# fi
	# info "Setting NODE_ENV to ${node_env}"
}

install_or_reuse_toolbox() {
	local layer_dir=$1

	info "Installing toolbox"
	mkdir -p "${layer_dir}/bin"

	if [[ ! -f "${layer_dir}/bin/yj" ]]; then
		info "- yj"
		curl -Ls https://github.com/sclevine/yj/releases/download/v2.0/yj-linux >"${layer_dir}/bin/yj" &&
			chmod +x "${layer_dir}/bin/yj"
	fi
	cat > "${layer_dir}.toml" <<TOML
[types]
cache = true
build = true
launch = false
TOML
}

store_python_version() {
	local layer_dir=$1
	local prev_python_version

	if [[ -f "${layer_dir}.toml" ]]; then
		# shellcheck disable=SC2002
		prev_python_version=$(cat "${layer_dir}.toml" | grep version | xargs | cut -d " " -f3)
		mkdir -p "${layer_dir}/env.build"

		if [[ -s "${layer_dir}/env.build/PREV_PYTHON_VERSION.override" ]]; then
			rm -rf "${layer_dir}/env.build/PREV_PYTHON_VERSION.override"
		fi

		info "Storing previous Python v${prev_python_version}"
		echo -e "$prev_python_version\c" >"${layer_dir}/env.build/PREV_PYTHON_VERSION.override"
	fi
}

install_or_reuse_python() {
	local layer_dir=$1
	local build_dir=$2

	local engine_python
	local python_version
	local resolved_data
	local python_url
	status "Installing Python"
	info "Getting Python version"
	engine_python=$(toml_get_key_from_tool_heroku "$build_dir/pyproject.toml" "engines.python")
	python_version=${engine_python:-3.9.x}

	info "Resolving Python version"
	info $(resolve-version python "$python_version")
	resolved_data=$(resolve-version python "$python_version")
	python_url=$(echo "$resolved_data" | cut -f2 -d " ")
	python_version=$(echo "$resolved_data" | cut -f1 -d " ")

	if [[ $python_version == $(toml_get_key_from_metadata "${layer_dir}.toml" "version") ]]; then
		info "Reusing Python v${python_version}"
	else
		info "Downloading and extracting Python ${python_version}"

		mkdir -p "${layer_dir}"
		rm -rf "${layer_dir:?}"/*

		curl -sL "$python_url" | tar xz -C "$layer_dir"
	fi
	{
			echo "[types]"
			echo "cache = true"
			echo "build = true"
			echo "launch = true"
			echo -e "[metadata]\nversion = \"$python_version\""
		} >"${layer_dir}.toml"
}

clear_cache_on_python_version_change() {
	local layers_dir=$1
	local layer_dir=$2
	local prev_python_version
	local curr_python_version

	curr_python_version="$(python --version | cut -d' ' -f2)"
	curr_python_version=${curr_python_version}
	if [[ -s "${layer_dir}/env.build/PREV_PYTHON_VERSION" ]]; then
		prev_python_version=$(cat "${layer_dir}/env.build/PREV_PYTHON_VERSION")

		if [[ "$curr_python_version" != "$prev_python_version" ]]; then
			info "Deleting cache because Python version changed from \"$prev_python_version\" to \"$curr_python_version\""
			# rm -rf "${layers_dir}/yarn" "${layers_dir}/yarn.toml"
		fi
	fi
}

parse_pyproject_toml_engines() {
	local layer_dir=$1
	local build_dir=$2

	local engine_poetry
	local engine_yarn
	local poetry_version
	local yarn_version
	local resolved_data
	local yarn_url
	status "Parsing pyproject.toml"
	info "Parsing pyproject.toml"

	engine_poetry=$(toml_get_key_from_tool_heroku "$build_dir/pyproject.toml" "engines.poetry")
	# engine_yarn=$(json_get_key "$build_dir/package.json" ".engines.yarn")

	poetry_version=${engine_poetry:-'1.1.*'}
	# yarn_version=${engine_yarn:-1.x}
	# resolved_data=$(resolve-version yarn "$yarn_version")
	# yarn_url=$(echo "$resolved_data" | cut -f2 -d " ")
	# yarn_version=$(echo "$resolved_data" | cut -f1 -d " ")

	cat <<TOML >"${layer_dir}.toml"
[types]
cache = false
build = true
launch = false

[metadata]
poetry_version = "$poetry_version"
# yarn_url = "$yarn_url"
# yarn_version = "$yarn_version"
TOML
}

install_or_reuse_pip() {
	local layer_dir=$1
	local build_dir=$2

	local engine_pip
	local engine_setuptools
	local pip_version
	local setuptools_version
	local resolved_data
	local pip_url
	local pip_wheel

	engine_pip=$(toml_get_key_from_tool_heroku "$build_dir/pyproject.toml" "engines.pip")
	pip_version=${engine_pip:-'*'}
	resolved_data=$(resolve-version pip "$pip_version")
	pip_version=$(echo "$resolved_data" | cut -f1 -d " ")
	pip_url=$(echo "$resolved_data" | cut -f2 -d " ")
	pip_wheel=$(echo "$resolved_data" | cut -f2 -d " ")


	status "Installing pip"
	if [[ $pip_version == $(toml_get_key_from_metadata "${layer_dir}.toml" "version") ]]; then
		info "Reusing pip==${pip_version}"
	else
		info "Installing pip ${pip_version}"

		mkdir -p "$layer_dir"
		rm -rf "${layer_dir:?}"/*
		wheel_file=$(echo $pip_url | rev | cut -d '/' -f1 | rev)
		curl -sLo "/tmp/$wheel_file" "$pip_url"
		python "/tmp/$wheel_file/pip" install --prefix="$layer_dir" --quiet --disable-pip-version-check --no-cache pip setuptools
	fi
		echo -e "[types]\ncache = true" >"${layer_dir}.toml"

		{
			echo "build = true"
			echo "launch = true"
			echo -e "[metadata]\nversion = \"$pip_version\""
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

sqlite3_install() {
  	local layer_dir=$1
	local headers_only=$2
	local tmpdir=$(mktemp -d)
	
	APT_CACHE_DIR="${tmpdir}/apt/cache"
	APT_STATE_DIR="${tmpdir}/apt/state"

	mkdir -p "${APT_CACHE_DIR}/archives/partial"
	mkdir -p "${APT_STATE_DIR}/lists/partial"

	APT_OPTIONS="-o debug::nolocking=true"
	APT_OPTIONS="$APT_OPTIONS -o dir::cache=$APT_CACHE_DIR"
	APT_OPTIONS="$APT_OPTIONS -o dir::state=$APT_STATE_DIR"
	APT_OPTIONS="$APT_OPTIONS -o dir::etc::sourcelist=/etc/apt/sources.list"

	apt-get $APT_OPTIONS update > /dev/null 2>&1
	if [ -z "$headers_only" ]; then
		apt-get $APT_OPTIONS -y -d --reinstall install libsqlite3-dev sqlite3 > /dev/null 2>&1
	else
		apt-get $APT_OPTIONS -y -d --reinstall install libsqlite3-dev
	fi

	find "$APT_CACHE_DIR/archives/" -name "*.deb" -exec dpkg -x {} "$tmpdir/sqlite3/" \;

	mkdir -p "$layer_dir/include" "$layer_dir/lib"

	# remove old sqlite3 libraries/binaries
	find "$layer_dir/include/" -name "sqlite3*.h" -exec rm -f {} \;
	find "$layer_dir/lib/" -name "libsqlite3.*" -exec rm -f {} \;
	rm -f "$layer_dir/lib/pkgconfig/sqlite3.pc"
	rm -f "$layer_dir/bin/sqlite3"

	# copy over sqlite3 headers & bins and setup linking against the stack image library
	mv "$tmpdir/sqlite3/usr/include/"* "$layer_dir/include/"
	mv "$tmpdir/sqlite3/usr/lib/x86_64-linux-gnu"/libsqlite3.*a "$layer_dir/lib/"
	mkdir -p "$layer_dir/lib/pkgconfig"
	# set the right prefix/lib directories
	sed -e 's/prefix=\/usr/prefix=\/app\/.heroku\/python/' -e 's/\/x86_64-linux-gnu//' "$tmpdir/sqlite3/usr/lib/x86_64-linux-gnu/pkgconfig/sqlite3.pc" > "$layer_dir/lib/pkgconfig/sqlite3.pc"
	# need to point the libsqlite3.so to the stack image library for /usr/bin/ld -lsqlite3
	SQLITE3_LIBFILE="/usr/lib/x86_64-linux-gnu/$(readlink -n "$tmpdir/sqlite3/usr/lib/x86_64-linux-gnu/libsqlite3.so")"
	ln -s "$SQLITE3_LIBFILE" "$layer_dir/lib/libsqlite3.so"
	if [ -z "$headers_only" ]; then
		mv "$tmpdir/sqlite3/usr/bin"/* "$layer_dir/bin/"
	fi
	dpkg -s libsqlite3-0 | grep '^Version: ' | cut -f2 -d' ' > $layer-dir/python-sqlite3-version
}

buildpack_sqlite3_install() {
local layer_dir=$1

SQLITE3_VERSION_FILE="$layer_dir/python-sqlite3-version"
if [ -f "$SQLITE3_VERSION_FILE" ]; then
	INSTALLED_SQLITE3_VERSION=$(cat "$SQLITE3_VERSION_FILE")
fi

info "Installing SQLite3"

if ! sqlite3_install "$layer_dir"; then
	echo "Sqlite3 failed to install."
fi
}
