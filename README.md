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
glib, pixman, libslirp, libfdt (dtc), zlib, libffi, pcre2, libaio and liburing.
Every binary and library has `RUNPATH=$ORIGIN/../lib`, and QEMU is built relocatable, so the tree works wherever it is extracted.

The minimum glibc is 2.27, the first release with `memfd_create()`, which libvhost-user in QEMU calls without a fallback.

The build enables TCG, KVM, user mode networking (slirp), passt, VNC, the VirtFS (9p) backend, Linux AIO and io_uring.
GUI frontends (GTK, SDL), audio other than OSS, TLS and seccomp are not built.

`aio=io_uring` needs Linux 5.1 or later, and fails where io_uring is blocked, such as under the default seccomp profile of Docker or with the `kernel.io_uring_disabled` sysctl.

`qemu-bridge-helper` is usually installed setuid, and the dynamic loader ignores `$ORIGIN` for setuid programs.
To use it setuid, the bundled libraries must be visible to the loader by other means, such as `ld.so.conf`.

# About release workflow
Releases are tagged with the release date in JST in SemVer form, such as `v2026.10.13`.
The versions of QEMU and the bundled libraries are listed in the release notes.

Renovate updates `version.json` when QEMU tags a new release, and the bundled library versions in `tasks/build.task.yml`.
When a change of the build inputs (`version.json`, `tasks/build.task.yml`, `src/` and the zig, ninja and uv versions) is merged, CI on the main branch builds the binaries and creates a release.
The release notes record a hash of the build inputs, and CI compares it with the latest release to decide whether to release.
Only one release can be made per day, so changes merged after the release of the day are released by the scheduled CI run on the next day.

To build another QEMU version, run the CI workflow manually with `build-version`.
Builds of a version other than the one in `version.json` are not released.

```console
$ gh workflow run ci -f build-version=11.1.1
```
