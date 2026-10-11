#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

#import <crt_externs.h>
#import <dlfcn.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "check.h"

// Frame generation: inert without NOTPROTON_FRAMEGEN, and with it the
// interpolated frame puts a moving square halfway between its two positions.

typedef void (*probe_fn)(int *, int *, int *, int *, int *, int *);
typedef int (*interpolate_fn)(id, id, id, id, int, double *);

static void *load_shim(const char *path, probe_fn *probe, interpolate_fn *interpolate)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (shim == NULL)
		return NULL;

	void (*install)(void) = (void (*)(void))dlsym(shim, "np_overlay_shim_install");
	*probe = (probe_fn)dlsym(shim, "np_framegen_probe");
	*interpolate = (interpolate_fn)dlsym(shim, "np_framegen_interpolate_sync");
	if (install != NULL)
		install();
	return shim;
}

// Drives the present path the way a game would, offscreen
static int present_frames(id<MTLDevice> device, CAMetalLayer *layer, int frames, int spacing_us)
{
	static id<MTLCommandQueue> queue;

	if (queue == nil)
		queue = [device newCommandQueue];

	for (int i = 0; i < frames; i++) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (drawable == nil)
				return 0;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
			pass.colorAttachments[0].texture = drawable.texture;
			pass.colorAttachments[0].loadAction = MTLLoadActionClear;
			pass.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
			[encoder endEncoding];
			[buffer presentDrawable:drawable];
			[buffer commit];
			[buffer waitUntilCompleted];
			usleep(spacing_us);
		}
	}
	return 1;
}

static CAMetalLayer *game_layer(id<MTLDevice> device)
{
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(256, 256);
	return layer;
}

static int inert_without_env(const char *path)
{
	probe_fn probe = NULL;
	interpolate_fn interpolate = NULL;

	CHECK(getenv("NOTPROTON_FRAMEGEN") == NULL, "NOTPROTON_FRAMEGEN is set in the parent");
	CHECK(load_shim(path, &probe, &interpolate) != NULL, "%s does not load: %s", path, dlerror());
	CHECK(probe != NULL, "%s exports no np_framegen_probe", path);
	CHECK(interpolate != NULL, "%s exports no np_framegen_interpolate_sync", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CHECK(present_frames(device, game_layer(device), 3, 20000), "offscreen layer vends no drawable");

	int enabled = -1, hooks = -1, mode = -1, objects = -1, generated = -1, copies = -1;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(enabled == 0, "framegen enabled without NOTPROTON_FRAMEGEN");
	CHECK(hooks == 0, "framegen installed %d hooks while off", hooks);
	CHECK(mode == 0, "framegen mode %d while off", mode);
	CHECK(objects == 0, "framegen created %d objects while off", objects);
	printf("%-14s %s\n", "framegen off", "no hooks, no objects");
	return 0;
}

static id<MTLTexture> square_frame(id<MTLDevice> device, NSUInteger width, NSUInteger height, int x0,
                                   int y0, int size)
{
	MTLTextureDescriptor *descriptor =
	        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                           width:width
	                                                          height:height
	                                                       mipmapped:NO];
	descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	descriptor.storageMode = MTLStorageModeShared;
	id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];

	uint32_t *pixels = calloc(width * height, 4);
	for (NSUInteger y = 0; y < height; y++) {
		for (NSUInteger x = 0; x < width; x++) {
			int inside = (int)x >= x0 && (int)x < x0 + size && (int)y >= y0 && (int)y < y0 + size;
			uint8_t g = (uint8_t)(((x / 8) * 5 + (y / 8) * 3) & 0x3f);
			pixels[y * width + x] = inside ? 0xffffffffu : (0xff000000u | (g << 16) | (g << 8) | g);
		}
	}
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
	           mipmapLevel:0
	             withBytes:pixels
	           bytesPerRow:width * 4];
	free(pixels);
	return texture;
}

// Bright pixels in the square's rows: how many and where their centre is
static void bright_pixels(id<MTLTexture> texture, int y0, int size, int *count, double *centre)
{
	NSUInteger width = texture.width;
	uint32_t *pixels = malloc(width * 4 * (size_t)size);
	[texture getBytes:pixels
	      bytesPerRow:width * 4
	       fromRegion:MTLRegionMake2D(0, y0, width, size)
	      mipmapLevel:0];
	double sum = 0;
	int n = 0;
	for (int y = 0; y < size; y++) {
		for (NSUInteger x = 0; x < width; x++) {
			uint32_t p = pixels[y * width + x];
			if (((p >> 16) & 0xff) > 180 && ((p >> 8) & 0xff) > 180 && (p & 0xff) > 180) {
				sum += x;
				n++;
			}
		}
	}
	free(pixels);
	*count = n;
	*centre = n > 0 ? sum / n : -1;
}

static int midpoint_square(interpolate_fn interpolate, id<MTLDevice> device, int engine,
                           const char *name)
{
	const NSUInteger width = 1024, height = 768;
	const int size = 120, y0 = 300, xa = 300, xb = 380;

	id<MTLTexture> a = square_frame(device, width, height, xa, y0, size);
	id<MTLTexture> b = square_frame(device, width, height, xb, y0, size);
	id<MTLTexture> out = square_frame(device, width, height, 0, 0, 0);
	double gpu_ms = 0;
	int used = interpolate(device, a, b, out, engine, &gpu_ms);
	if (used == 0 && engine == 2) {
		printf("%-14s %s\n", name, "skipped: MetalFX frame interpolation unavailable here");
		return 0;
	}
	CHECK(used == engine, "engine %s did not run (got %d)", name, used);

	int count = 0;
	double centre = -1;
	bright_pixels(out, y0, size, &count, &centre);
	double expected = (xa + xb) / 2.0 + size / 2.0;
	printf("%-14s square centre %.1f (expected %.1f), %d bright pixels (square %d), %.2f ms GPU\n",
	       name, centre, expected, count, size * size, gpu_ms);
	CHECK(count > size * size * 6 / 10 && count < size * size * 14 / 10,
	      "%s: %d bright pixels, a crossfade or a smear rather than a moved square", name, count);
	CHECK(centre > expected - 12 && centre < expected + 12,
	      "%s: square centre %.1f is not near the midpoint %.1f", name, centre, expected);
	return 0;
}

static int full_frame_cost(interpolate_fn interpolate, id<MTLDevice> device, int engine,
                           const char *name)
{
	const NSUInteger width = 3024, height = 1964;
	id<MTLTexture> a = square_frame(device, width, height, 1000, 800, 200);
	id<MTLTexture> b = square_frame(device, width, height, 1100, 800, 200);
	id<MTLTexture> out = square_frame(device, width, height, 0, 0, 0);
	double gpu_ms = 0;
	int used = interpolate(device, a, b, out, engine, &gpu_ms);
	if (used != engine)
		return 0;
	printf("%-14s %lux%lu: %.2f ms GPU per generated frame\n", name, (unsigned long)width,
	       (unsigned long)height, gpu_ms);
	return 0;
}

static int child_with_env(const char *path)
{
	probe_fn probe = NULL;
	interpolate_fn interpolate = NULL;

	CHECK(load_shim(path, &probe, &interpolate) != NULL, "%s does not load: %s", path, dlerror());
	CHECK(probe != NULL && interpolate != NULL, "%s exports no framegen entry points", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");

	int enabled = 0, hooks = 0, mode = 0, objects = 0, generated = 0, copies = 0;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(enabled == 1, "NOTPROTON_FRAMEGEN=1 did not enable framegen");

	// The present path must survive with framegen on, offscreen
	CAMetalLayer *layer = game_layer(device);
	CHECK(present_frames(device, layer, 8, 20000), "offscreen layer vends no drawable");
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(hooks >= 4, "framegen installed %d hooks, expected the present family and commit", hooks);
	printf("%-14s hooks=%d mode=%d objects=%d\n", "framegen on", hooks, mode, objects);

	// Let the worker finish building, then run slow enough that it engages
	for (int i = 0; i < 100 && mode == 1; i++) {
		usleep(50000);
		probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	}
	CHECK(mode == 3, "framegen mode %d after setup, expected pass-through", mode);
	CHECK(present_frames(device, layer, 60, 25000), "offscreen layer vends no drawable");
	usleep(200000);
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(mode == 2, "framegen mode %d after 60 frames at 40 fps, expected active", mode);
	CHECK(copies > 0, "no real frame copy presented while active");
	CHECK(generated > 0, "no frame generated while active");
	printf("%-14s %d real copies, %d generated at 40 fps\n", "framegen path", copies, generated);
	double burst_start = CACurrentMediaTime();
	CHECK(present_frames(device, layer, 40, 0), "offscreen layer vends no drawable");
	double burst_ms = (CACurrentMediaTime() - burst_start) * 1000.0;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(mode == 3, "framegen mode %d after a fast burst (40 frames in %.1f ms), expected pass-through",
	      mode, burst_ms);
	printf("%-14s back to pass-through above the refresh rate (40 frames in %.1f ms)\n",
	       "framegen fast", burst_ms);

	int rc = midpoint_square(interpolate, device, 1, "own engine");
	if (rc != 0)
		return rc;
	rc = midpoint_square(interpolate, device, 2, "metalfx");
	if (rc != 0)
		return rc;
	full_frame_cost(interpolate, device, 1, "own engine");
	full_frame_cost(interpolate, device, 2, "metalfx");
	return 0;
}

int main(int argc, char **argv)
{
	const char *path = getenv("NOTPROTON_OVERLAY_SHIM");

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");

	if (getenv("NP_FRAMEGEN_TEST_CHILD") != NULL)
		return child_with_env(path);

	int rc = inert_without_env(path);
	if (rc != 0)
		return rc;

	// The shim reads the environment when it loads, so the on case is a child
	char **environ_now = *_NSGetEnviron();
	int count = 0;
	while (environ_now[count] != NULL)
		count++;
	char **env = calloc((size_t)count + 3, sizeof(char *));
	memcpy(env, environ_now, (size_t)count * sizeof(char *));
	env[count] = "NOTPROTON_FRAMEGEN=1";
	env[count + 1] = "NP_FRAMEGEN_TEST_CHILD=1";

	fflush(stdout);
	pid_t pid;
	char *args[] = { argv[0], NULL };
	(void)argc;
	CHECK(posix_spawn(&pid, argv[0], NULL, NULL, args, env) == 0, "cannot spawn %s", argv[0]);
	int status = 0;
	CHECK(waitpid(pid, &status, 0) == pid, "waitpid failed");
	CHECK(WIFEXITED(status), "framegen child did not exit cleanly (status %d)", status);
	return WEXITSTATUS(status);
}
