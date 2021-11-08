#!/usr/bin/env bash

toml_get_key_from_metadata() {
	local file="$1"
	local key="$2"

	if test -f "$file"; then
		yj -t <"${file}" | jq -r ".metadata.${key}"
	else
		echo ""
	fi
}

toml_get_key_from_tool_heroku() {
	local file="$1"
	local key="$2"

	if test -f "$file"; then
		yj -t <"${file}" | jq -r ".tool.heroku.${key} | select (.!=null)"
	else
		echo ""
	fi
}
