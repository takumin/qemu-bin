#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Test an extracted release tarball. Only bash, coreutils, grep, ldd and
# script (util-linux) are used, so the same script runs on the host and in an
# Ubuntu 18.04 container with the minimum glibc.
#
# usage: run.sh <prefix> <assets> <workdir>
#
#   prefix   the extracted release tarball
#   assets   kernels and initramfs images made by the test:assets task
#   workdir  scratch directory, on a filesystem that supports O_DIRECT
#
# The KVM tests are skipped when /dev/kvm is not usable, unless
# QEMU_BIN_TEST_REQUIRE_KVM=1 is set.
#
# The FUSE test is skipped when /dev/fuse is not usable, or fusermount3 is
# not installed for a user other than root, unless QEMU_BIN_TEST_REQUIRE_FUSE=1
# is set.
#
# The curses test runs with TERM=${QEMU_BIN_TEST_TERM:-xterm-256color}.

set -euo pipefail

prefix="$(cd "$1" && pwd -P)"
assets="$(cd "$2" && pwd)"
workdir="$3"

boot_timeout=600

section() {
	echo
	echo "=== $*"
}

run() {
	echo "+ $*" >&2
	"$@"
}

die() {
	echo "error: $*" >&2
	exit 1
}

have_kvm() {
	[[ -r /dev/kvm && -w /dev/kvm ]]
}

# A user other than root mounts with the setuid fusermount3 of the system
have_fuse() {
	[[ -r /dev/fuse && -w /dev/fuse ]] && { [[ "$(id -u)" == 0 ]] || command -v fusermount3 >/dev/null; }
}

# Stop the daemons left by a failed test, so the FUSE export is unmounted
pidfiles=()
cleanup() {
	local f
	for f in "${pidfiles[@]}"; do
		[[ -s "${f}" ]] && kill "$(cat "${f}")" 2>/dev/null || true
	done
}
trap cleanup EXIT

rm -rf "${workdir}"
mkdir -p "${workdir}"
workdir="$(cd "${workdir}" && pwd)"

section "System"
uname -a
ldd --version | sed -n 1p
if have_kvm; then
	echo "KVM: available"
elif [[ "${QEMU_BIN_TEST_REQUIRE_KVM:-}" == 1 ]]; then
	die "/dev/kvm is not usable"
else
	echo "KVM: not available, the KVM tests are skipped"
fi
echo "UID: $(id -u)"
if have_fuse; then
	echo "FUSE: available$(command -v fusermount3 >/dev/null && echo ", $(fusermount3 --version 2>&1)")"
elif [[ "${QEMU_BIN_TEST_REQUIRE_FUSE:-}" == 1 ]]; then
	die "/dev/fuse or fusermount3 is not usable"
else
	echo "FUSE: not available, the FUSE test is skipped"
fi

################################################################################
# Binaries
################################################################################

# The TCG plugins in lib/qemu/plugins are only loaded by QEMU, which has
# already loaded glib, and are tested by loading them below.
section "Shared libraries"
for f in "${prefix}"/bin/* "${prefix}"/libexec/* "${prefix}"/lib/*.so*; do
	echo "${f#"${prefix}"/}"
	out="$(ldd "${f}" 2>&1)" || die "ldd ${f}: ${out}"
	if grep -E 'not found|not a dynamic' <<<"${out}"; then
		die "${f} does not load"
	fi
	# Everything but glibc must resolve to the bundled libraries
	while read -r lib path; do
		case "${lib}" in
		linux-vdso.so.* | ld-linux-*.so.* | libc.so.* | libm.so.* | libpthread.so.* | libdl.so.* | librt.so.* | libresolv.so.* | libutil.so.*) ;;
		*) [[ "$(realpath "${path}")" == "${prefix}/lib/${lib}" ]] || die "${f}: ${lib} resolves to ${path}" ;;
		esac
	done < <(sed -n 's/^\s*\(\S*\) => \(\S*\) .*/\1 \2/p' <<<"${out}")
done

section "Version"
for b in qemu-system-x86_64 qemu-system-aarch64 qemu-img qemu-io qemu-nbd qemu-storage-daemon qemu-pr-helper; do
	run "${prefix}/bin/${b}" --version | sed -n 1p
done
run "${prefix}/bin/qemu-edid" -h >/dev/null

section "libcap-ng"
# The helpers only take the user and group to drop privileges to, and only
# drop capabilities, when they are built with libcap-ng
run "${prefix}/bin/qemu-pr-helper" --help | grep -e '--user=USER' || die "qemu-pr-helper is built without libcap-ng"

################################################################################
# Block layer
################################################################################

qemu_img() { run "${prefix}/bin/qemu-img" "$@"; }
qemu_io() { run "${prefix}/bin/qemu-io" "$@"; }

section "qemu-img: qcow2"
img="${workdir}/test.qcow2"
qemu_img create -f qcow2 "${img}" 64M
qemu_io -f qcow2 -c 'write -P 0x5a 0 1M' -c 'read -P 0x5a 0 1M' "${img}"
qemu_img check "${img}"
qemu_img convert -f qcow2 -O raw "${img}" "${workdir}/test.raw"
qemu_img compare -f qcow2 -F raw "${img}" "${workdir}/test.raw"
qemu_img info "${img}"

section "qemu-img: qcow2 with zstd compression"
zst="${workdir}/test-zstd.qcow2"
qemu_img create -f qcow2 -o compression_type=zstd "${zst}" 16M
qemu_io -f qcow2 -c 'write -c -P 0x66 0 1M' -c 'read -P 0x66 0 1M' "${zst}"
qemu_img convert -c -f qcow2 -O qcow2 -o compression_type=zstd "${img}" "${workdir}/test-convert-zstd.qcow2"
qemu_img compare -f qcow2 -F qcow2 "${img}" "${workdir}/test-convert-zstd.qcow2"
for f in "${zst}" "${workdir}/test-convert-zstd.qcow2"; do
	qemu_img check "${f}"
	qemu_img info "${f}" | grep 'compression type: zstd' >/dev/null || die "${f} is not compressed with zstd"
done

section "qemu-io: AIO backends"
for aio in threads native io_uring; do
	qemu_io -f qcow2 --cache none --aio "${aio}" \
		-c 'write -P 0x11 2M 1M' -c 'read -P 0x11 2M 1M' -c 'flush' "${img}"
done

section "qemu-img: LUKS (nettle)"
secret=(--object 'secret,id=sec0,data=qemu-bin-test')
luks="${workdir}/test.luks"
qemu_img create "${secret[@]}" -f luks -o key-secret=sec0 "${luks}" 16M
qemu_io "${secret[@]}" --image-opts -c 'write -P 0x33 0 1M' -c 'read -P 0x33 0 1M' \
	"driver=luks,key-secret=sec0,file.filename=${luks}"
enc="${workdir}/test-luks.qcow2"
qemu_img create "${secret[@]}" -f qcow2 -o encrypt.format=luks,encrypt.key-secret=sec0 "${enc}" 16M
qemu_io "${secret[@]}" --image-opts -c 'write -P 0x44 0 1M' -c 'read -P 0x44 0 1M' \
	"driver=qcow2,encrypt.key-secret=sec0,file.filename=${enc}"
qemu_img info "${enc}" | grep 'encrypted: yes' >/dev/null || die "${enc} is not encrypted"

section "FUSE export"
if have_fuse; then
	fuse_img="${workdir}/fuse.qcow2"
	fuse_pid="${workdir}/fuse.pid"
	mnt="${workdir}/fuse.raw"
	qemu_img create -f qcow2 "${fuse_img}" 16M
	: >"${mnt}"
	pidfiles+=("${fuse_pid}")
	run "${prefix}/bin/qemu-storage-daemon" \
		--blockdev "driver=file,node-name=file0,filename=${fuse_img}" \
		--blockdev 'driver=qcow2,node-name=disk0,file=file0' \
		--export "type=fuse,id=exp0,node-name=disk0,mountpoint=${mnt},writable=on" \
		--pidfile "${fuse_pid}" --daemonize
	grep -q " ${mnt} " /proc/self/mountinfo || die "${mnt} is not mounted"
	qemu_io -f raw -c 'write -P 0x77 0 1M' -c 'read -P 0x77 0 1M' -c 'flush' "${mnt}"
	# SEEK_DATA and SEEK_HOLE (fuse-lseek) find the unallocated clusters
	out="$(qemu_img map --output=json -f raw "${mnt}")"
	echo "${out}"
	grep -q '"data": false' <<<"${out}" || die "the export does not report holes"
	pid="$(cat "${fuse_pid}")"
	kill "${pid}"
	for _ in $(seq 300); do
		kill -0 "${pid}" 2>/dev/null || break
		sleep 0.1
	done
	! kill -0 "${pid}" 2>/dev/null || die "qemu-storage-daemon does not exit"
	pidfiles=()
	! grep -q " ${mnt} " /proc/self/mountinfo || die "${mnt} is not unmounted"
	qemu_io -f qcow2 -c 'read -P 0x77 0 1M' "${fuse_img}"
else
	echo "skipped"
fi

################################################################################
# QMP
################################################################################

# qmp <system> <accel> <command>...: run the commands on an empty machine
qmp() {
	local system="$1" accel="$2"
	shift 2
	{
		echo '{"execute": "qmp_capabilities"}'
		for c in "$@"; do
			echo "{\"execute\": \"${c}\"}"
		done
		echo '{"execute": "quit"}'
	} | run timeout 60 "${prefix}/bin/qemu-system-${system}" \
		-machine none -accel "${accel}" -nodefaults -display none \
		-sandbox on -qmp stdio
}

for system in x86_64 aarch64; do
	section "QMP: ${system} / tcg"
	out="$(qmp "${system}" tcg query-version query-kvm)"
	echo "${out}"
	grep -q '"enabled": false' <<<"${out}" || die "KVM is enabled with -accel tcg"
done

if have_kvm; then
	section "QMP: x86_64 / kvm"
	out="$(qmp x86_64 kvm query-version query-kvm)"
	echo "${out}"
	grep -q '"enabled": true, "present": true' <<<"${out}" || die "KVM is not enabled"
fi

################################################################################
# TCG plugins
################################################################################

section "TCG plugins"
[[ -f "${prefix}/include/qemu-plugin.h" ]] || die "qemu-plugin.h is not installed"
plugins="${prefix}/lib/qemu/plugins"
ls "${plugins}"
# SeaBIOS runs far more instructions than the limit, and stoptrigger exits
# with the given code when the guest reaches it.
code=0
run timeout 60 "${prefix}/bin/qemu-system-x86_64" \
	-machine pc -accel tcg -nodefaults -display none -sandbox on \
	-plugin "${plugins}/libstoptrigger.so,icount=100000:42" \
	-plugin "${plugins}/libhotblocks.so" \
	-d plugin -D "${workdir}/plugin.log" || code=$?
cat "${workdir}/plugin.log"
[[ "${code}" == 42 ]] || die "qemu-system-x86_64 exited with ${code}, not the stoptrigger exit code"
grep -q 'icount reached' "${workdir}/plugin.log" || die "stoptrigger did not stop the guest"

################################################################################
# curses
################################################################################

# SeaBIOS prints its messages on the VGA text console, which the curses
# display draws on the terminal of script. With no bootable device, SeaBIOS
# reboots at once with reboot-timeout=0, and QEMU exits with -no-reboot.
term="${QEMU_BIN_TEST_TERM:-xterm-256color}"
section "curses display: TERM=${term}"
terminfo="not installed, the built-in description is used"
for d in "${HOME}/.terminfo" /etc/terminfo /lib/terminfo /usr/share/terminfo; do
	if [[ -e "${d}/${term:0:1}/${term}" ]]; then
		terminfo="${d}/${term:0:1}/${term}"
		break
	fi
done
echo "terminfo: ${terminfo}"
code=0
TERM="${term}" run timeout 60 script -qec "$(printf '%q ' \
	"${prefix}/bin/qemu-system-x86_64" \
	-machine pc -accel tcg -nodefaults -vga std -display curses -sandbox on \
	-boot reboot-timeout=0 -no-reboot)" \
	"${workdir}/curses.log" </dev/null >/dev/null || code=$?
[[ "${code}" == 0 ]] || {
	cat -v "${workdir}/curses.log"
	die "qemu-system-x86_64 exited with ${code}"
}
grep -aq 'No bootable device' "${workdir}/curses.log" || {
	cat -v "${workdir}/curses.log"
	die "the curses display did not draw the console"
}
echo "drawn: $(grep -ao 'BIOS (version [^)]*)' "${workdir}/curses.log" | head -1)"

################################################################################
# Guest boot
################################################################################

# boot <system> <accel> <aio>: boot the test guest, which checks the
# accelerator, a virtio-blk disk and user mode networking, then powers off
boot() {
	local system="$1" accel="$2" aio="$3"
	local name="${system}-${accel}"
	local disk="${workdir}/${name}.qcow2"
	local log="${workdir}/${name}.log"
	local -a args

	section "Boot: ${system} / ${accel} / aio=${aio}"

	# The guest reads the magic at the start of the disk and writes a pattern
	printf 'qemu-bin-test-disk' >"${workdir}/${name}.raw"
	truncate -s 16M "${workdir}/${name}.raw"
	qemu_img convert -f raw -O qcow2 "${workdir}/${name}.raw" "${disk}"
	mkdir -p "${workdir}/share"

	case "${system}" in
	x86_64)
		args=(-machine q35 -cpu "$([[ "${accel}" == kvm ]] && echo host || echo max)")
		console=ttyS0
		;;
	aarch64)
		args=(-machine virt -cpu max)
		console=ttyAMA0
		;;
	esac
	args+=(
		-accel "${accel}" -smp 2 -m 256M
		-nodefaults -display none -vnc none -serial stdio -no-reboot
		-sandbox on
		-kernel "${assets}/vmlinuz-${system}"
		-initrd "${assets}/initramfs-${system}"
		-append "console=${console} quiet panic=-1 qemu_bin_test_accel=${accel}"
		-drive "if=none,id=disk0,file=${disk},format=qcow2,cache.direct=on,aio=${aio}"
		-device 'virtio-blk-pci,drive=disk0'
		-netdev "user,id=net0,restrict=on,guestfwd=tcp:10.0.2.100:1234-cmd:echo qemu-bin-test-net"
		-device 'virtio-net-pci,netdev=net0'
		-virtfs "local,path=${workdir}/share,mount_tag=share,security_model=none"
	)

	if ! run timeout "${boot_timeout}" "${prefix}/bin/qemu-system-${system}" "${args[@]}" </dev/null | tee "${log}"; then
		die "qemu-system-${system} failed"
	fi
	grep -q '^qemu-bin-test: PASS' "${log}" || die "the guest did not pass the tests"
	qemu_io -f qcow2 -c 'read -P 0xa5 1M 64k' "${disk}"
	qemu_img check "${disk}"
}

if have_kvm; then
	boot x86_64 kvm io_uring
fi
boot x86_64 tcg native
boot aarch64 tcg io_uring

section "All tests passed"
