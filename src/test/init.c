// SPDX-License-Identifier: MIT
//
// /init of the test guest. It checks the devices given by run.sh, prints
// "qemu-bin-test: PASS" or "qemu-bin-test: FAIL" on the console and powers
// off. Parameters come from the kernel command line through the environment:
//
//   qemu_bin_test_accel  expected accelerator on x86 (kvm or tcg)

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <cpuid.h>
#endif

#define DISK "/dev/vda"
#define DISK_MAGIC "qemu-bin-test-disk"
#define DISK_WRITE_OFFSET (1024 * 1024)
#define DISK_WRITE_SIZE (64 * 1024)
#define DISK_WRITE_PATTERN 0xa5
#define NET_IFNAME "eth0"
#define NET_ADDR "10.0.2.15"
#define NET_MASK "255.255.255.0"
#define NET_PEER "10.0.2.100"
#define NET_PORT 1234
#define NET_MAGIC "qemu-bin-test-net"

static int failed;

static void say(const char *fmt, ...) {
	va_list ap;
	printf("qemu-bin-test: ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
}

static void fail(const char *fmt, ...) {
	va_list ap;
	printf("qemu-bin-test: error: ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
	failed = 1;
}

static void load_module(const char *name) {
	char path[64];
	snprintf(path, sizeof(path), "/lib/modules/%s.ko", name);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		fail("open %s: %s", path, strerror(errno));
		return;
	}
	if (syscall(SYS_finit_module, fd, "", 0) != 0 && errno != EEXIST) {
		fail("load %s: %s", name, strerror(errno));
	}
	close(fd);
}

static void check_accel(void) {
#if defined(__x86_64__)
	const char *want = getenv("qemu_bin_test_accel");
	const char *sig = strcmp(want ? want : "", "kvm") == 0 ? "KVMKVMKVM" : "TCGTCGTCGTCG";
	unsigned int a, b, c, d;
	char got[13] = {0};
	__cpuid(0x40000000, a, b, c, d);
	memcpy(got + 0, &b, 4);
	memcpy(got + 4, &c, 4);
	memcpy(got + 8, &d, 4);
	if (strcmp(got, sig) != 0) {
		fail("hypervisor signature is '%s', expected '%s'", got, sig);
		return;
	}
	say("hypervisor signature %s", got);
#endif
}

static void check_disk(void) {
	struct stat st;
	int i;
	for (i = 0; i < 300 && stat(DISK, &st) != 0; i++) {
		usleep(100 * 1000);
	}
	int fd = open(DISK, O_RDWR | O_DIRECT | O_CLOEXEC);
	if (fd < 0) {
		fail("open %s: %s", DISK, strerror(errno));
		return;
	}
	void *buf;
	if (posix_memalign(&buf, 4096, DISK_WRITE_SIZE) != 0) {
		fail("posix_memalign");
		close(fd);
		return;
	}
	if (pread(fd, buf, 4096, 0) != 4096) {
		fail("read %s: %s", DISK, strerror(errno));
	} else if (memcmp(buf, DISK_MAGIC, strlen(DISK_MAGIC)) != 0) {
		fail("%s does not start with %s", DISK, DISK_MAGIC);
	} else {
		say("read %s from %s", DISK_MAGIC, DISK);
	}
	memset(buf, DISK_WRITE_PATTERN, DISK_WRITE_SIZE);
	if (pwrite(fd, buf, DISK_WRITE_SIZE, DISK_WRITE_OFFSET) != DISK_WRITE_SIZE || fsync(fd) != 0) {
		fail("write %s: %s", DISK, strerror(errno));
	} else {
		say("wrote %d bytes of 0x%02x to %s", DISK_WRITE_SIZE, DISK_WRITE_PATTERN, DISK);
	}
	free(buf);
	close(fd);
}

static int set_ifaddr(int s, unsigned long req, const char *addr) {
	struct ifreq ifr = {0};
	struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
	strncpy(ifr.ifr_name, NET_IFNAME, IFNAMSIZ - 1);
	sin->sin_family = AF_INET;
	inet_pton(AF_INET, addr, &sin->sin_addr);
	return ioctl(s, req, &ifr);
}

static void check_net(void) {
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	struct ifreq ifr = {0};
	strncpy(ifr.ifr_name, NET_IFNAME, IFNAMSIZ - 1);
	if (s < 0 || set_ifaddr(s, SIOCSIFADDR, NET_ADDR) != 0 || set_ifaddr(s, SIOCSIFNETMASK, NET_MASK) != 0 ||
	    ioctl(s, SIOCGIFFLAGS, &ifr) != 0) {
		fail("configure %s: %s", NET_IFNAME, strerror(errno));
		return;
	}
	ifr.ifr_flags |= IFF_UP;
	if (ioctl(s, SIOCSIFFLAGS, &ifr) != 0) {
		fail("up %s: %s", NET_IFNAME, strerror(errno));
		return;
	}
	close(s);

	struct sockaddr_in peer = {.sin_family = AF_INET, .sin_port = htons(NET_PORT)};
	inet_pton(AF_INET, NET_PEER, &peer.sin_addr);
	struct timeval tv = {.tv_sec = 10};
	char buf[64] = {0};
	ssize_t n = -1;
	int i;
	for (i = 0; i < 10 && n < 0; i++) {
		s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
		setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		if (connect(s, (struct sockaddr *)&peer, sizeof(peer)) == 0) {
			n = read(s, buf, sizeof(buf) - 1);
		}
		if (n < 0) {
			sleep(1);
		}
		close(s);
	}
	if (n < 0) {
		fail("connect %s:%d: %s", NET_PEER, NET_PORT, strerror(errno));
	} else if (strncmp(buf, NET_MAGIC, strlen(NET_MAGIC)) != 0) {
		fail("received '%s' from %s:%d, expected %s", buf, NET_PEER, NET_PORT, NET_MAGIC);
	} else {
		say("received %s from %s:%d", NET_MAGIC, NET_PEER, NET_PORT);
	}
}

int main(void) {
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	say("started");

	check_accel();
	load_module("failover");
	load_module("net_failover");
	load_module("virtio_net");
	load_module("virtio_blk");
	check_disk();
	check_net();

	say(failed ? "FAIL" : "PASS");
	sync();
	reboot(RB_POWER_OFF);
	for (;;) {
		pause();
	}
}
