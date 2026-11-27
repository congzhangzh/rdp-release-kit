/*
 * v4l2-reader: a CI-only diagnostic for probe-camera-linux, never shipped. It reads frames from a
 * capture device with read() (V4L2's read/write I/O), where v4l2-ctl --stream-mmap uses mmap
 * streaming, to tell the two apart.
 *
 * The fd is blocking and the first read() comes before any poll(): v4l2loopback answers poll()
 * only for an opener it knows as a reader: in 0.12.7 and 0.13.0 opener->type READER, which only
 * VIDIOC_STREAMON sets (v4l2loopback.c:1743 of 0.12.7), never read(); in 0.15.x the capture
 * format token, which the first read() takes (start_fileio: REQBUFS and STREAMON). A reader that
 * polls first waits for ever (run 46071318124: "no frame within the timeout" on 0.12.7 while the
 * mmap reader got 150 frames). Each read() has an alarm() as its timeout.
 *
 *   v4l2-reader <device> <frames> <out file> [timeout s per frame, default 5]
 *
 * It prints the capture format (VIDIOC_G_FMT), then how many frames it read and how each read
 * ended; exit 0 when it read them all, 1 otherwise.
 *
 * Copyright 2026 Cong Zhang <congzhangzh@gmail.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static void on_alarm(int sig)
{
	(void)sig; /* only to interrupt read() with EINTR */
}

int main(int argc, char* argv[])
{
	if (argc < 4)
	{
		fprintf(stderr, "usage: %s <device> <frames> <out file> [timeout s]\n", argv[0]);
		return 2;
	}
	const unsigned long want = strtoul(argv[2], NULL, 10);
	const int timeout = (argc > 4) ? atoi(argv[4]) : 5;

	/* no SA_RESTART: the alarm interrupts a read() that waits too long */
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_alarm;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGALRM, &sa, NULL);

	const int fd = open(argv[1], O_RDONLY);
	if (fd < 0)
	{
		printf("open %s: %s\n", argv[1], strerror(errno));
		return 1;
	}
	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_G_FMT, &fmt) < 0)
	{
		printf("VIDIOC_G_FMT: %s\n", strerror(errno));
		return 1;
	}
	char fourcc[5] = { 0 };
	memcpy(fourcc, &fmt.fmt.pix.pixelformat, 4);
	const size_t size = fmt.fmt.pix.sizeimage;
	printf("capture format: %s %ux%u, sizeimage %zu\n", fourcc, fmt.fmt.pix.width,
	       fmt.fmt.pix.height, size);
	if (size == 0)
		return 1;

	unsigned char* frame = malloc(size);
	FILE* out = fopen(argv[3], "wb");
	if (!frame || !out)
		return 1;

	unsigned long got = 0;
	while (got < want)
	{
		alarm((unsigned)timeout);
		const ssize_t n = read(fd, frame, size);
		const int err = errno;
		alarm(0);
		if (n < 0)
		{
			printf("frame %lu: %s\n", got,
			       (err == EINTR) ? "no frame within the timeout" : strerror(err));
			break;
		}
		if ((size_t)n != size)
			printf("frame %lu: %zd bytes, not %zu\n", got, n, size);
		if (fwrite(frame, 1, (size_t)n, out) != (size_t)n)
			return 1;
		got++;
	}
	printf("read() frames: %lu of %lu\n", got, want);
	fclose(out);
	close(fd);
	return (got == want) ? 0 : 1;
}
