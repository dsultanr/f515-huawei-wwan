/*
 * huawei-modeswitch — переводит Huawei-модем из storage-режима (12d1:14fe и т.п.)
 * в режим с AT/PPP-портами (12d1:1506) без usb_modeswitch и без Frida.
 *
 * Ровно то же, что делает usb_modeswitch: 31-байтовая SCSI-команда (CBW) в bulk-OUT
 * endpoint mass-storage-интерфейса, отправленная напрямую через usbfs
 * (/dev/bus/usb/BBB/DDD). После неё модем сам переподключается уже с новым PID,
 * поэтому ошибка на записи вида ENODEV/EIO — это НЕ сбой, а ожидаемый результат.
 *
 * Сборка: tools/build-tools.sh (статически, aarch64).
 * Запуск на голове: huawei-modeswitch [-n] [/dev/bus/usb/BBB/DDD]
 *   -n   только показать, что найдено, ничего не отправлять
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/usbdevice_fs.h>

#define HUAWEI_VENDOR 0x12d1

/* PID'ы, в которых модем притворяется флешкой/CD-ROM и AT-портов не отдаёт. */
static const uint16_t storage_pids[] = { 0x14fe, 0x1f01, 0x1f02, 0x1446, 0x14ad, 0x1c0b };

/*
 * Сообщение из upstream-конфига usb_modeswitch для Huawei (TargetProduct=0x1506).
 * Это стандартный CBW: signature "USBC", tag, длина, флаги + SCSI-команда 0x11 0x06.
 */
static const uint8_t switch_msg[31] = {
	0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x11, 0x06, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

/* Дескрипторы разбираем сами, чтобы не тянуть linux/usb/ch9.h из чужого sysroot. */
struct desc_hdr { uint8_t bLength; uint8_t bDescriptorType; };

#define DT_DEVICE    0x01
#define DT_INTERFACE 0x04
#define DT_ENDPOINT  0x05

struct found {
	uint16_t vid, pid;
	int      ifnum;   /* mass-storage интерфейс */
	int      ep_out;  /* его bulk-OUT endpoint  */
};

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static int is_storage_pid(uint16_t pid)
{
	size_t i;
	for (i = 0; i < sizeof(storage_pids) / sizeof(storage_pids[0]); i++)
		if (storage_pids[i] == pid)
			return 1;
	return 0;
}

/*
 * usbfs отдаёт по read() дескриптор устройства, а следом все конфигурации.
 * Идём по ним линейно и запоминаем первый mass-storage интерфейс (класс 0x08)
 * вместе с его bulk-OUT endpoint'ом.
 */
static int parse_descriptors(int fd, struct found *f)
{
	uint8_t buf[4096];
	ssize_t n = read(fd, buf, sizeof(buf));
	ssize_t i = 0;
	int in_storage_iface = 0;

	if (n < 18)
		return -1;

	f->ifnum = -1;
	f->ep_out = -1;

	while (i + 2 <= n) {
		const struct desc_hdr *h = (const struct desc_hdr *)(buf + i);

		if (h->bLength < 2 || i + h->bLength > n)
			break;

		if (h->bDescriptorType == DT_DEVICE && h->bLength >= 18) {
			f->vid = le16(buf + i + 8);
			f->pid = le16(buf + i + 10);
		} else if (h->bDescriptorType == DT_INTERFACE && h->bLength >= 9) {
			uint8_t ifnum = buf[i + 2];
			uint8_t iclass = buf[i + 5];

			in_storage_iface = (iclass == 0x08);
			if (in_storage_iface && f->ifnum < 0)
				f->ifnum = ifnum;
		} else if (h->bDescriptorType == DT_ENDPOINT && h->bLength >= 7) {
			uint8_t addr = buf[i + 2];
			uint8_t attr = buf[i + 3];

			/* bulk (attr&3==2) и направление OUT (бит 7 сброшен) */
			if (in_storage_iface && (attr & 0x03) == 0x02 &&
			    !(addr & 0x80) && f->ep_out < 0)
				f->ep_out = addr;
		}
		i += h->bLength;
	}
	return f->ifnum >= 0 ? 0 : -1;
}

/* Ищем первый Huawei в storage-режиме. path[] заполняется найденным узлом usbfs. */
static int find_device(char *path, size_t pathlen, struct found *f)
{
	DIR *buses = opendir("/dev/bus/usb");
	struct dirent *b;
	int rc = -1;

	if (!buses) {
		fprintf(stderr, "нет /dev/bus/usb: %s\n", strerror(errno));
		return -1;
	}

	while ((b = readdir(buses)) != NULL && rc != 0) {
		char busdir[512];
		DIR *devs;
		struct dirent *d;

		if (b->d_name[0] == '.')
			continue;
		snprintf(busdir, sizeof(busdir), "/dev/bus/usb/%s", b->d_name);
		devs = opendir(busdir);
		if (!devs)
			continue;

		while ((d = readdir(devs)) != NULL) {
			char node[1024];
			int fd;
			struct found cur;

			if (d->d_name[0] == '.')
				continue;
			snprintf(node, sizeof(node), "%s/%s", busdir, d->d_name);
			fd = open(node, O_RDWR);
			if (fd < 0)
				fd = open(node, O_RDONLY);
			if (fd < 0)
				continue;

			memset(&cur, 0, sizeof(cur));
			if (parse_descriptors(fd, &cur) == 0 &&
			    cur.vid == HUAWEI_VENDOR && is_storage_pid(cur.pid)) {
				snprintf(path, pathlen, "%s", node);
				*f = cur;
				rc = 0;
			}
			close(fd);
			if (rc == 0)
				break;
		}
		closedir(devs);
	}
	closedir(buses);
	return rc;
}

static int send_switch(const char *node, const struct found *f)
{
	struct usbdevfs_ioctl detach;
	struct usbdevfs_bulktransfer bulk;
	int fd, ifnum = f->ifnum, transferred;

	fd = open(node, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", node, strerror(errno));
		return 1;
	}

	/* usb-storage уже держит интерфейс — вежливо просим ядро его отпустить. */
	memset(&detach, 0, sizeof(detach));
	detach.ifno = ifnum;
	detach.ioctl_code = USBDEVFS_DISCONNECT;
	if (ioctl(fd, USBDEVFS_IOCTL, &detach) < 0 && errno != ENODATA)
		fprintf(stderr, "предупреждение: disconnect ifno=%d: %s\n", ifnum, strerror(errno));

	if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifnum) < 0) {
		fprintf(stderr, "claim ifno=%d: %s\n", ifnum, strerror(errno));
		close(fd);
		return 1;
	}

	memset(&bulk, 0, sizeof(bulk));
	bulk.ep = (unsigned int)f->ep_out;
	bulk.len = sizeof(switch_msg);
	bulk.timeout = 3000;
	bulk.data = (void *)switch_msg;

	transferred = ioctl(fd, USBDEVFS_BULK, &bulk);
	if (transferred < 0) {
		/*
		 * Модем часто отваливается прямо в момент приёма команды — для нас
		 * это штатный успех, проверять надо по появлению нового PID.
		 */
		fprintf(stderr, "bulk: %s (обычно это норма — модем уже переподключается)\n",
			strerror(errno));
	} else {
		printf("отправлено %d байт в ep 0x%02x\n", transferred, f->ep_out);
	}

	ioctl(fd, USBDEVFS_RELEASEINTERFACE, &ifnum);
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	char node[512] = "";
	struct found f;
	int dry_run = 0, i;

	memset(&f, 0, sizeof(f));

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-n") == 0)
			dry_run = 1;
		else
			snprintf(node, sizeof(node), "%s", argv[i]);
	}

	if (node[0]) {
		int fd = open(node, O_RDWR);

		if (fd < 0)
			fd = open(node, O_RDONLY);
		if (fd < 0) {
			fprintf(stderr, "open %s: %s\n", node, strerror(errno));
			return 1;
		}
		if (parse_descriptors(fd, &f) != 0) {
			fprintf(stderr, "%s: mass-storage интерфейс не найден\n", node);
			close(fd);
			return 2;
		}
		close(fd);
	} else if (find_device(node, sizeof(node), &f) != 0) {
		fprintf(stderr, "Huawei в storage-режиме не найден "
				"(модем уже переключён или не воткнут)\n");
		return 2;
	}

	printf("устройство: %s  %04x:%04x  storage-интерфейс %d  bulk-OUT ep 0x%02x\n",
	       node, f.vid, f.pid, f.ifnum, f.ep_out);

	if (f.ep_out < 0) {
		fprintf(stderr, "bulk-OUT endpoint не найден — отправлять команду некуда\n");
		return 3;
	}
	if (dry_run) {
		printf("dry-run: команда не отправлена\n");
		return 0;
	}
	if (f.vid != HUAWEI_VENDOR)
		fprintf(stderr, "предупреждение: это не Huawei (vid %04x)\n", f.vid);

	return send_switch(node, &f);
}
