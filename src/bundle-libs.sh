#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Copy the shared libraries needed by the ELF files in <stage>/bin and
# <stage>/libexec from <libdir> into <stage>/lib, following DT_NEEDED
# recursively. Libraries not found in <libdir> (glibc) are left to the system.
#
# usage: bundle-libs.sh <libdir> <stage>

set -euo pipefail

libdir="$1"
stage="$2"

needed() {
	readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'
}

coreutils mkdir -p "${stage}/lib"

queue=()
for f in "${stage}"/bin/* "${stage}"/libexec/*; do
	queue+=("${f}")
done

while [[ ${#queue[@]} -gt 0 ]]; do
	f="${queue[0]}"
	queue=("${queue[@]:1}")
	while read -r lib; do
		if [[ ! -e "${libdir}/${lib}" || -e "${stage}/lib/${lib}" ]]; then
			continue
		fi
		echo "${lib}"
		# Install under the SONAME, which is the only name the loader uses.
		coreutils cp -L "${libdir}/${lib}" "${stage}/lib/${lib}"
		queue+=("${stage}/lib/${lib}")
	done < <(needed "${f}")
done
