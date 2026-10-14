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
lib/*.so.*
share/qemu/*
share/doc/*/*     (licenses of QEMU and the bundled libraries)
```

Only glibc is used from the system.
The other libraries are built from source as shared libraries and bundled in `lib/`:
glib, pixman, libslirp, libfdt (dtc), zlib, libffi, pcre2, libaio, liburing, libseccomp, nettle and zstd.
Every binary and library has `RUNPATH=$ORIGIN/../lib`, and QEMU is built relocatable, so the tree works wherever it is extracted.

The minimum glibc is 2.27, the first release with `memfd_create()`, which libvhost-user in QEMU calls without a fallback.

The build enables TCG, KVM, user mode networking (slirp), passt, VNC, the VirtFS (9p) backend, Linux AIO, io_uring, the seccomp sandbox (`-sandbox on`) and zstd compression.
zstd compresses qcow2 images (`compression_type=zstd`) and migration streams (`multifd-compression=zstd`).
nettle is the crypto backend, so LUKS images (`qemu-img create -f luks`, qcow2 `encrypt.format=luks`) and VNC password authentication work.
GUI frontends (GTK, SDL), audio other than OSS, TLS and public key algorithms (virtio-crypto akcipher) are not built.

`aio=io_uring` needs Linux 5.1 or later, and fails where io_uring is blocked, such as under the default seccomp profile of Docker or with the `kernel.io_uring_disabled` sysctl.

`qemu-bridge-helper` is usually installed setuid, and the dynamic loader ignores `$ORIGIN` for setuid programs.
To use it setuid, the bundled libraries must be visible to the loader by other means, such as `ld.so.conf`.

# About tests
CI tests the `x86_64-linux-gnu` tarball before signing and releasing it, on the x86_64 runner where KVM is available.
The tests run on the runner and again in an Ubuntu 18.04 container to check the minimum glibc:

- Every binary and library loads, and resolves the libraries other than glibc to the bundled ones.
- `qemu-img` and `qemu-io` read and write qcow2 images with the threads, Linux AIO and io_uring backends, zstd compressed qcow2 images and LUKS images.
- An empty machine is started over QMP with KVM and TCG.
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
