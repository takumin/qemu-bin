# qemu-bin
Prebuilt binaries of [QEMU](https://www.qemu.org/) built with `zig cc`.

| Target | Minimum glibc |
| --- | --- |
| `x86_64-linux-gnu` | 2.27 |
| `aarch64-linux-gnu` | 2.27 |

Each release asset is a tarball laid out for `/usr/local`:

```
bin/qemu-system-aarch64
bin/qemu-system-x86_64
bin/qemu-img
bin/qemu-io
bin/qemu-nbd
bin/qemu-storage-daemon
bin/qemu-edid
bin/qemu-pr-helper
bin/qemu-vmsr-helper
libexec/qemu-bridge-helper
include/qemu-plugin.h
lib/*.so.*
lib/qemu/plugins/*.so   (TCG plugins from QEMU's contrib/plugins)
share/qemu/*
share/doc/*/*     (licenses of QEMU and the bundled libraries)
```

Only glibc is used from the system.
The other libraries are built from source as shared libraries and bundled in `lib/`:
glib, pixman, libslirp, libfdt (dtc), zlib, libffi, pcre2, libaio, liburing, libseccomp, nettle, zstd, libcap-ng, libfuse and ncurses.
Every binary and library has `RUNPATH=$ORIGIN/../lib`, and QEMU is built relocatable, so the tree works wherever it is extracted.

The minimum glibc is 2.27, the first release with `memfd_create()`, which libvhost-user in QEMU calls without a fallback.

The build enables TCG, KVM, user mode networking (slirp), passt, VNC, the curses display, the VirtFS (9p) backend, Linux AIO, io_uring, FUSE exports, the seccomp sandbox (`-sandbox on`), zstd compression and TCG plugins.
zstd compresses qcow2 images (`compression_type=zstd`) and migration streams (`multifd-compression=zstd`).
TCG plugins instrument guests run with TCG, such as `-plugin lib/qemu/plugins/libhotblocks.so -d plugin`.
Other plugins can be built against `include/qemu-plugin.h` and the system glib headers.
The plugins in `lib/qemu/plugins` are meant to be loaded by QEMU only, and use the glib that QEMU has loaded.
nettle is the crypto backend, so LUKS images (`qemu-img create -f luks`, qcow2 `encrypt.format=luks`) and VNC password authentication work.
GUI frontends (GTK, SDL), audio other than OSS, TLS and public key algorithms (virtio-crypto akcipher) are not built.

`-display curses` shows the text console of the guest in the terminal.
The bundled ncurses reads the terminal descriptions from `/etc/terminfo`, `/lib/terminfo` and `/usr/share/terminfo`, as well as from `TERMINFO`, `TERMINFO_DIRS` and `~/.terminfo`.
Where none of them has the description of `TERM`, such as in a container without terminfo, the descriptions built into ncurses are used for `linux`, `vt100`, `vt220`, `xterm`, `xterm-256color`, `screen`, `screen-256color`, `tmux` and `tmux-256color`.

`qemu-storage-daemon --export type=fuse` exports a block device as a regular file, such as `--export type=fuse,id=exp0,node-name=disk0,mountpoint=disk.raw,writable=on`, where `disk.raw` is an existing file.
A user other than root mounts it with the setuid `fusermount3`, which is not bundled and comes from the fuse3 package of the system.
libfuse looks for it in `/usr/local/bin` and then in `PATH`.
The user also needs access to `/dev/fuse`, which a container usually lacks.
To let other users access the export (`allow-other=on`), `user_allow_other` must be set in `/etc/fuse.conf`.
With the default `allow-other=auto`, the export is made accessible to its owner only when it is not set.

`aio=io_uring` needs Linux 5.1 or later, and fails where io_uring is blocked, such as under the default seccomp profile of Docker or with the `kernel.io_uring_disabled` sysctl.

`-netdev passt` gives the guest user mode networking through [passt](https://passt.top/), which is faster than slirp and needs no privileges.
passt is not bundled, and QEMU runs the `passt` found in `PATH`, or the one given by `path=`.
Prebuilt passt is available from [passt-bin](https://github.com/takumin/passt-bin), which [aqua](https://aquaproj.github.io/) installs together with this package:

```console
$ aqua g -i takumin/qemu-bin takumin/passt-bin
$ aqua i
```

The `passt` that aqua puts in `PATH` picks its version from the `aqua.yaml` of the current directory or the global configuration of aqua.
Where QEMU runs outside of them, give the real path, such as `path=$(aqua which passt)`.

With `vhost-user=on`, passt reads and writes the guest memory directly, so the guest RAM must be shared:

```console
$ qemu-system-x86_64 -machine q35,memory-backend=mem \
    -object memory-backend-memfd,id=mem,size=1G,share=on \
    -netdev passt,id=net0,vhost-user=on \
    -device virtio-net-pci,netdev=net0
```

passt announces the MTU of 65520 over DHCP and NDP, and a guest that configures its address statically should set it as well, since the guest receives much faster with it than with the MTU of 1500.
passt started by QEMU inherits the seccomp filter of `-sandbox on` and is killed by it.
To use both, start passt first and connect QEMU to its socket:

```console
$ passt --vhost-user --socket-path "${XDG_RUNTIME_DIR}/passt.socket"
$ qemu-system-x86_64 -sandbox on -machine q35,memory-backend=mem \
    -object memory-backend-memfd,id=mem,size=1G,share=on \
    -chardev socket,id=chr0,path="${XDG_RUNTIME_DIR}/passt.socket" \
    -netdev vhost-user,id=net0,chardev=chr0 \
    -device virtio-net-pci,netdev=net0
```

libcap-ng lets `qemu-bridge-helper`, `qemu-pr-helper` and `qemu-vmsr-helper` drop the capabilities they do not need, and `qemu-pr-helper` take `--user` and `--group` to drop privileges to.

`qemu-bridge-helper` is usually installed setuid, and the dynamic loader ignores `$ORIGIN` for setuid programs.
To use it setuid, the bundled libraries must be visible to the loader by other means, such as `ld.so.conf`.

# About tests
CI tests the `x86_64-linux-gnu` tarball before signing and releasing it, on the x86_64 runner where KVM is available.
The tests run on the runner and again in an Ubuntu 18.04 container to check the minimum glibc:

- Every binary and library loads, and resolves the libraries other than glibc to the bundled ones.
- `qemu-pr-helper` is built with libcap-ng.
- `qemu-img` and `qemu-io` read and write qcow2 images with the threads, Linux AIO and io_uring backends, zstd compressed qcow2 images and LUKS images.
- On the runner, `qemu-storage-daemon` exports a qcow2 image over FUSE, which the runner user mounts with `fusermount3`, and the export is read, written and reports holes.
- An empty machine is started over QMP with KVM and TCG.
- The stoptrigger plugin stops a TCG guest after a given number of instructions.
- The curses display draws the messages of SeaBIOS in a terminal made by `script`.
  The test in the container hides the terminfo databases, so the descriptions built into ncurses are used.
- A guest boots on x86_64 with KVM and TCG and on aarch64 with TCG, under `-sandbox on`.
  Its `/init` (`src/test/init.c`) checks the accelerator, reads and writes a virtio-blk disk and connects to the host through user mode networking.

The guest kernels and modules are taken from the netboot files of Alpine Linux, pinned by hash in `tasks/test.task.yml`.
The `aarch64-linux-gnu` tarball is built from the same recipe and is not tested.

```console
$ task build:prepare
$ task test
```

# About release workflow
Releases are tagged with the release date in JST in SemVer form, such as `v2026.10.13`.
The versions of QEMU and the bundled libraries are listed in the release notes.

Renovate updates `version.json` when QEMU tags a new release, the bundled library versions in `tasks/build.task.yml`, and meson in `pyproject.toml` together with them.
The Python version in `.python-version` is updated by hand, since a new Python release does not change the binaries.
When a change of the build inputs (`version.json`, `tasks/build.task.yml`, `src/`, the zig, ninja and uv versions, and the Python and meson versions in `.python-version` and `uv.lock`) is merged, CI on the main branch builds the binaries and creates a release.
The release notes record a hash of the build inputs, and CI compares it with the latest release to decide whether to release.
Only one release can be made per day, so changes merged after the release of the day are released by the scheduled CI run on the next day.

To build another QEMU version, run the CI workflow manually with `build-version`.
Builds of a version other than the one in `version.json` are not released.

```console
$ gh workflow run ci -f build-version=11.1.1
```
