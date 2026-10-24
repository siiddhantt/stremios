#import "MSWebPImageDecoder.h"
#include "../Vendor/libwebp/src/webp/decode.h"
#include <math.h>
static void MSReleaseWebPPixels(void *info, const void *data, size_t size) { (void)info; (void)size; free((void *)data); }
UIImage *MSDecodeWebPThumbnail(NSData *data, NSUInteger maxPixels) {
    if (data.length < 20 || data.length > 2 * 1024 * 1024) return nil;
    const uint8_t *bytes = data.bytes;
    if (memcmp(bytes, "RIFF", 4) || memcmp(bytes + 8, "WEBP", 4)) return nil;
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config) || WebPGetFeatures(bytes, data.length, &config.input) != VP8_STATUS_OK) return nil;
    if (config.input.has_animation || config.input.width <= 0 || config.input.height <= 0 ||
        (uint64_t)config.input.width * config.input.height > 4 * 1024 * 1024) return nil;
    maxPixels = MAX(32, MIN(maxPixels, 1200));
    double ratio = MIN(1.0, (double)maxPixels / MAX(config.input.width, config.input.height));
    int width = MAX(1, (int)floor(config.input.width * ratio)), height = MAX(1, (int)floor(config.input.height * ratio));
    size_t count = (size_t)width * height * 4;
    uint8_t *pixels = calloc(1, count); if (!pixels) return nil;
    config.options.use_scaling = 1; config.options.scaled_width = width; config.options.scaled_height = height;
    config.options.use_threads = 0;
    config.output.colorspace = MODE_rgbA; config.output.is_external_memory = 1;
    config.output.u.RGBA.rgba = pixels; config.output.u.RGBA.stride = width * 4; config.output.u.RGBA.size = count;
    VP8StatusCode status = WebPDecode(bytes, data.length, &config);
    WebPFreeDecBuffer(&config.output);
    if (status != VP8_STATUS_OK) { free(pixels); return nil; }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, count, MSReleaseWebPPixels);
    if (!provider) { free(pixels); return nil; }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, color, kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast, provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *result = image ? [UIImage imageWithCGImage:image] : nil;
    if (image) CGImageRelease(image); CGColorSpaceRelease(color); CGDataProviderRelease(provider);
    return result;
}
