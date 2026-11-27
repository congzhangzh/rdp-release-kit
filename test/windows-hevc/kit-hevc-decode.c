/* The CI's HEVC decode test for the kit's Windows client (test/windows-hevc):
 *
 *   kit-hevc-decode.exe <stream.hevc> <420|444>
 *
 * decodes one HEVC picture (make-streams.sh) through FreeRDP's freerdp_hevc_* API, linked from the
 * client's own build tree (inject.cmake), so the decoder FreeRDP picks is the one the shipped
 * client would pick on this machine: Media Foundation when Windows has an HEVC decoder for it,
 * else FFmpeg's libavcodec. Then it checks the centre of each quadrant against its colour and says
 * which decoder ran. Exit code 0: decoded, every quadrant right; 1 otherwise. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/wtypes.h>
#include <freerdp/codec/color.h>
#include <freerdp/codec/hevc.h>

#define WIDTH 256
#define HEIGHT 256

/* make-streams.sh's quadrants (R, G, B), as TestFreeRDPCodecHEVC.c's */
static const BYTE quadrant_colours[4][3] = {
	{ 230, 30, 30 },  /* top left: red */
	{ 30, 200, 30 },  /* top right: green */
	{ 30, 30, 230 },  /* bottom left: blue */
	{ 230, 220, 30 }, /* bottom right: yellow */
};

static BYTE* read_file(const char* path, size_t* size)
{
	FILE* f = fopen(path, "rb");
	if (!f)
		return NULL;
	BYTE* data = NULL;
	if ((fseek(f, 0, SEEK_END) == 0))
	{
		const long len = ftell(f);
		if ((len > 0) && (fseek(f, 0, SEEK_SET) == 0) && (data = malloc((size_t)len)) &&
		    (fread(data, 1, (size_t)len, f) != (size_t)len))
		{
			free(data);
			data = NULL;
		}
		*size = (len > 0) ? (size_t)len : 0;
	}
	(void)fclose(f);
	return data;
}

int main(int argc, char* argv[])
{
	if ((argc != 3) || ((strcmp(argv[2], "420") != 0) && (strcmp(argv[2], "444") != 0)))
	{
		(void)fprintf(stderr, "usage: %s <stream.hevc> <420|444>\n", argv[0]);
		return 1;
	}
	const UINT32 profile = (strcmp(argv[2], "444") == 0) ? 1 : 0;
	const char* name = profile ? "HEVC 4:4:4" : "HEVC 4:2:0";
	const UINT32 step = WIDTH * 4;
	const RECTANGLE_16 rect = { 0, 0, WIDTH, HEIGHT };
	int rc = 1;
	size_t size = 0;
	BYTE* coded = read_file(argv[1], &size);
	BYTE* dst = calloc(HEIGHT, step);
	FREERDP_HEVC_CONTEXT* dec = freerdp_hevc_context_new(FALSE);
	FREERDP_DECODE_RESULT result = { 0 };

	if (!coded || (size == 0) || (size > UINT32_MAX))
	{
		(void)fprintf(stderr, "%s: FAIL: cannot read %s\n", name, argv[1]);
		goto out;
	}
	if (!dst || !dec)
	{
		(void)fprintf(stderr, "%s: FAIL: no HEVC decoder in this build\n", name);
		goto out;
	}
	/* 4:4:4 selects the decoder again: Media Foundation declines it (4:2:0 output only) */
	if (!freerdp_hevc_context_set_option(dec, FREERDP_HEVC_CONTEXT_OPTION_PROFILE, profile) ||
	    !freerdp_hevc_context_reset(dec, WIDTH, HEIGHT))
	{
		(void)fprintf(stderr, "%s: FAIL: no decoder takes this profile\n", name);
		goto out;
	}
	const INT32 status = freerdp_hevc_decompress(dec, coded, (UINT32)size, dst, PIXEL_FORMAT_BGRX32,
	                                             step, WIDTH, HEIGHT, &rect, 1);
	if (!freerdp_hevc_context_get_last_decode(dec, &result))
		goto out;
	const char* hardware = (result.hardware == FREERDP_DECODE_HARDWARE_YES)  ? "hardware"
	                       : (result.hardware == FREERDP_DECODE_HARDWARE_NO) ? "software"
	                                                                         : "unknown";
	(void)printf("%s: decoder %s (%s), status %d, decompress %" PRId32 "\n", name,
	             result.backend ? result.backend : "unknown", hardware, (int)result.status, status);
	if ((status < 0) || (result.status != FREERDP_DECODE_PICTURE))
	{
		(void)fprintf(stderr, "%s: FAIL: no picture\n", name);
		goto out;
	}

	rc = 0;
	for (size_t q = 0; q < 4; q++)
	{
		const size_t x = ((q & 1) ? 3 : 1) * WIDTH / 4;
		const size_t y = ((q & 2) ? 3 : 1) * HEIGHT / 4;
		const BYTE* p = &dst[y * step + 4 * x]; /* BGRX */
		const BYTE c[3] = { p[2], p[1], p[0] };
		int worst = 0;
		for (size_t k = 0; k < 3; k++)
		{
			const int d = abs((int)c[k] - (int)quadrant_colours[q][k]);
			if (d > worst)
				worst = d;
		}
		(void)printf("%s: quadrant %u is (%u, %u, %u), want (%u, %u, %u), off by %d%s\n", name,
		             (unsigned)q, c[0], c[1], c[2], quadrant_colours[q][0], quadrant_colours[q][1],
		             quadrant_colours[q][2], worst, (worst > 24) ? ", more than 24: WRONG" : "");
		if (worst > 24)
			rc = 1;
	}
	(void)printf("%s: %s\n", name, rc ? "FAIL" : "PASS");

out:
	freerdp_hevc_context_free(dec);
	free(dst);
	free(coded);
	return rc;
}
