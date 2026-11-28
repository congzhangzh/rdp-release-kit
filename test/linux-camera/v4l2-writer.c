/*
 * v4l2-writer: a CI-only camera source for test/linux-camera (kit.yml), never shipped. It writes frames to
 * a v4l2loopback device with write(), the path every v4l2loopback version has (GStreamer's
 * v4l2sink did not deliver frames to 0.12.7 nor negotiate MJPEG with 0.15.3: run 46079009433).
 *
 *   v4l2-writer <device> yuyv <width> <height> <fps>
 *       a test pattern drawn here: grey bars, and a white square that moves on every frame
 *   v4l2-writer <device> mjpg <width> <height> <fps> <frame.jpg>...
 *       the given JPEG files, in turn (made by the test with GStreamer's jpegenc)
 *
 * It sets the device's output format (VIDIOC_S_FMT, then VIDIOC_S_PARM for the frame rate),
 * then writes a frame every 1/fps s until it is killed, and says so on stdout: the format the
 * device took, the first frame, then every 300th.
 *
 * Copyright 2026 Cong Zhang <congzhangzh@gmail.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static unsigned char* read_file(const char* path, size_t* size)
{
	FILE* fp = fopen(path, "rb");
	if (!fp)
		return NULL;
	unsigned char* data = NULL;
	if ((fseek(fp, 0, SEEK_END) == 0))
	{
		const long n = ftell(fp);
		if ((n > 0) && (fseek(fp, 0, SEEK_SET) == 0))
		{
			data = malloc((size_t)n);
			if (data && (fread(data, 1, (size_t)n, fp) != (size_t)n))
			{
				free(data);
				data = NULL;
			}
			*size = (size_t)n;
		}
	}
	fclose(fp);
	return data;
}

/* grey bars, and a 64x64 white square moving 8 pixels a frame */
static void draw_yuyv(unsigned char* frame, unsigned width, unsigned height, unsigned long n)
{
	const unsigned side = 64;
	const unsigned span = (width > side) ? width - side : 1;
	const unsigned x0 = (unsigned)((n * 8) % span);
	const unsigned y0 = (height > side) ? (height - side) / 2 : 0;
	for (unsigned y = 0; y < height; y++)
	{
		unsigned char* row = frame + (size_t)y * width * 2;
		for (unsigned x = 0; x < width; x++)
		{
			unsigned char luma = (unsigned char)(40 + 160 * (x * 4 / width) / 3);
			if ((x >= x0) && (x < x0 + side) && (y >= y0) && (y < y0 + side))
				luma = 235;
			row[2 * x] = luma;
			row[2 * x + 1] = 128;
		}
	}
}

int main(int argc, char* argv[])
{
	if (argc < 6)
	{
		fprintf(stderr, "usage: %s <device> yuyv|mjpg <width> <height> <fps> [frame.jpg...]\n",
		        argv[0]);
		return 2;
	}
	const char* device = argv[1];
	const int mjpg = strcmp(argv[2], "mjpg") == 0;
	const unsigned width = (unsigned)strtoul(argv[3], NULL, 10);
	const unsigned height = (unsigned)strtoul(argv[4], NULL, 10);
	const unsigned fps = (unsigned)strtoul(argv[5], NULL, 10);
	if ((!mjpg && strcmp(argv[2], "yuyv") != 0) || (width < 64) || (height < 64) || (width % 2) ||
	    (fps == 0) || (mjpg && (argc < 7)))
	{
		fprintf(stderr, "%s: bad arguments\n", argv[0]);
		return 2;
	}

	/* the frames: one buffer for yuyv, redrawn; every JPEG file for mjpg */
	const size_t rawSize = (size_t)width * height * 2;
	const int files = mjpg ? argc - 6 : 0;
	unsigned char** jpeg = NULL;
	size_t* jpegSize = NULL;
	size_t largest = 0;
	unsigned char* raw = NULL;
	if (mjpg)
	{
		jpeg = calloc((size_t)files, sizeof(*jpeg));
		jpegSize = calloc((size_t)files, sizeof(*jpegSize));
		if (!jpeg || !jpegSize)
			return 1;
		for (int i = 0; i < files; i++)
		{
			jpeg[i] = read_file(argv[6 + i], &jpegSize[i]);
			if (!jpeg[i])
			{
				fprintf(stderr, "%s: cannot read %s\n", argv[0], argv[6 + i]);
				return 1;
			}
			if (jpegSize[i] > largest)
				largest = jpegSize[i];
		}
	}
	else if (!(raw = malloc(rawSize)))
		return 1;

	const int fd = open(device, O_RDWR);
	if (fd < 0)
	{
		fprintf(stderr, "%s: open %s: %s\n", argv[0], device, strerror(errno));
		return 1;
	}

	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = width;
	fmt.fmt.pix.height = height;
	fmt.fmt.pix.pixelformat = mjpg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_YUYV;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	fmt.fmt.pix.bytesperline = mjpg ? 0 : width * 2;
	/* a JPEG frame is written whole: the buffer holds the largest one (and a raw frame's size,
	 * whichever is more) */
	fmt.fmt.pix.sizeimage = (uint32_t)(mjpg ? ((largest > rawSize) ? largest : rawSize) : rawSize);
	fmt.fmt.pix.colorspace = mjpg ? V4L2_COLORSPACE_JPEG : V4L2_COLORSPACE_SMPTE170M;
	if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0)
	{
		fprintf(stderr, "%s: VIDIOC_S_FMT: %s\n", argv[0], strerror(errno));
		return 1;
	}
	char fourcc[5] = { 0 };
	memcpy(fourcc, &fmt.fmt.pix.pixelformat, 4);
	printf("format: %s %ux%u, sizeimage %u\n", fourcc, fmt.fmt.pix.width, fmt.fmt.pix.height,
	       fmt.fmt.pix.sizeimage);
	if ((fmt.fmt.pix.width != width) || (fmt.fmt.pix.height != height) ||
	    (fmt.fmt.pix.pixelformat != (mjpg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_YUYV)))
	{
		fprintf(stderr, "%s: the device took another format\n", argv[0]);
		return 1;
	}

	struct v4l2_streamparm parm;
	memset(&parm, 0, sizeof(parm));
	parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	parm.parm.output.timeperframe.numerator = 1;
	parm.parm.output.timeperframe.denominator = fps;
	if (ioctl(fd, VIDIOC_S_PARM, &parm) < 0)
		printf("VIDIOC_S_PARM %u fps: %s (going on)\n", fps, strerror(errno));
	fflush(stdout);

	struct timespec next;
	clock_gettime(CLOCK_MONOTONIC, &next);
	for (unsigned long n = 0;; n++)
	{
		const unsigned char* data = NULL;
		size_t size = 0;
		if (mjpg)
		{
			data = jpeg[n % (unsigned long)files];
			size = jpegSize[n % (unsigned long)files];
		}
		else
		{
			draw_yuyv(raw, width, height, n);
			data = raw;
			size = rawSize;
		}
		const ssize_t written = write(fd, data, size);
		if (written != (ssize_t)size)
		{
			fprintf(stderr, "%s: write of frame %lu: %s\n", argv[0], n,
			        (written < 0) ? strerror(errno) : "short");
			return 1;
		}
		if ((n == 0) || ((n % 300) == 0))
		{
			printf("frame %lu written (%zu bytes)\n", n, size);
			fflush(stdout);
		}
		next.tv_nsec += 1000000000L / fps;
		while (next.tv_nsec >= 1000000000L)
		{
			next.tv_nsec -= 1000000000L;
			next.tv_sec++;
		}
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
	}
}
