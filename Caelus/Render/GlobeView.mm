#import "GlobeView.h"
#import "Shaders.h"

#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#include "../Core/Propagation/SunCalculator.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

// MARK: - Types shared with the shaders

namespace {

struct FrameUniforms {
    simd_float4x4 viewProjection;
    simd_float4 sunDirection;
    simd_float4 cameraPosition;
};

struct PointUniforms {
    simd_float4x4 viewProjection;
    simd_float4 color;
    float pointSize;
    float pad0, pad1, pad2;
};

struct EarthVertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
};

struct LineVertex {
    float px, py, pz;
    float r, g, b, a;
};

struct StarVertex {
    float px, py, pz;
    float r, g, b, a;
    float size;
};

struct Layer {
    caelus::SatelliteGroup group;
    id<MTLBuffer> buffer = nil;
    std::vector<size_t> indices;
    size_t count = 0;
    bool visible = true;
    simd_float4 color{1, 1, 1, 1};
    float pointScale = 1.0f;
    float haloAlpha = 0.11f;
};

struct LineBatch {
    id<MTLBuffer> buffer = nil;
    std::vector<std::pair<NSUInteger, NSUInteger>> runs;
    bool visible = false;
    bool additive = true;
};

struct RigPose {
    float latitude = 22;
    float longitude = 8;
    float distance = 3.5f;
};

struct RigState {
    RigPose target;
    RigPose current;
};

}  // namespace

// MARK: - Colour helpers

static simd_float4 colorForGroup(caelus::SatelliteGroup group) {
    switch (group) {
        case caelus::SatelliteGroup::stations: return simd_make_float4(0.949f, 0.965f, 1.0f, 1);
        case caelus::SatelliteGroup::starlink: return simd_make_float4(0.302f, 0.608f, 1.0f, 1);
        case caelus::SatelliteGroup::navigation: return simd_make_float4(0.239f, 0.863f, 0.592f, 1);
        case caelus::SatelliteGroup::weather: return simd_make_float4(1.0f, 0.706f, 0.329f, 1);
        case caelus::SatelliteGroup::science: return simd_make_float4(0.710f, 0.549f, 1.0f, 1);
        case caelus::SatelliteGroup::other: return simd_make_float4(0.431f, 0.490f, 0.573f, 1);
    }
    return simd_make_float4(1, 1, 1, 1);
}

static float pointScaleForGroup(caelus::SatelliteGroup group) {
    switch (group) {
        case caelus::SatelliteGroup::stations: return 1.5f;
        case caelus::SatelliteGroup::starlink: return 0.72f;
        case caelus::SatelliteGroup::navigation: return 1.0f;
        case caelus::SatelliteGroup::weather: return 1.0f;
        case caelus::SatelliteGroup::science: return 1.05f;
        case caelus::SatelliteGroup::other: return 0.85f;
    }
    return 1.0f;
}

// MARK: - Matrix helpers

static simd_float4x4 perspectiveMatrix(float fovY, float aspect, float zNear, float zFar) {
    const float ys = 1.0f / std::tan(fovY * 0.5f);
    const float xs = ys / aspect;
    const float zs = zFar / (zNear - zFar);
    simd_float4x4 m;
    m.columns[0] = simd_make_float4(xs, 0, 0, 0);
    m.columns[1] = simd_make_float4(0, ys, 0, 0);
    m.columns[2] = simd_make_float4(0, 0, zs, -1);
    m.columns[3] = simd_make_float4(0, 0, zs * zNear, 0);
    return m;
}

static simd_float4x4 lookAtMatrix(simd_float3 eye, simd_float3 center, simd_float3 up) {
    const simd_float3 forward = simd_normalize(center - eye);
    const simd_float3 side = simd_normalize(simd_cross(forward, up));
    const simd_float3 trueUp = simd_cross(side, forward);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(side.x, trueUp.x, -forward.x, 0);
    m.columns[1] = simd_make_float4(side.y, trueUp.y, -forward.y, 0);
    m.columns[2] = simd_make_float4(side.z, trueUp.z, -forward.z, 0);
    m.columns[3] = simd_make_float4(-simd_dot(side, eye), -simd_dot(trueUp, eye),
                                   simd_dot(forward, eye), 1);
    return m;
}

static simd_float3 scenePoint(const caelus::sky::Vec3& v) {
    return simd_make_float3(static_cast<float>(v.x), static_cast<float>(v.y),
                            static_cast<float>(v.z));
}

// MARK: - Mesh and sky generation

namespace {

std::vector<EarthVertex> sphereVertices(float radius, int segments, int rings) {
    std::vector<EarthVertex> vertices;
    vertices.reserve(static_cast<size_t>((segments + 1) * (rings + 1)));

    for (int j = 0; j <= rings; ++j) {
        const float v = static_cast<float>(j) / static_cast<float>(rings);
        const double lat = -90.0 + 180.0 * static_cast<double>(v);
        for (int i = 0; i <= segments; ++i) {
            const float u = static_cast<float>(i) / static_cast<float>(segments);
            const double lon = -180.0 + 360.0 * static_cast<double>(u);
            const caelus::sky::Vec3 unit = caelus::GeoMath::unitVector(lat, lon);
            EarthVertex vertex;
            vertex.px = static_cast<float>(unit.x) * radius;
            vertex.py = static_cast<float>(unit.y) * radius;
            vertex.pz = static_cast<float>(unit.z) * radius;
            vertex.nx = static_cast<float>(unit.x);
            vertex.ny = static_cast<float>(unit.y);
            vertex.nz = static_cast<float>(unit.z);
            vertex.u = u;
            // The image's top row (v = 0) is the north pole, matching an
            // equirectangular map; without this flip the globe is mirrored.
            vertex.v = 1.0f - v;
            vertices.push_back(vertex);
        }
    }
    return vertices;
}

std::vector<uint32_t> sphereIndices(int segments, int rings) {
    std::vector<uint32_t> indices;
    const uint32_t columns = static_cast<uint32_t>(segments + 1);
    indices.reserve(static_cast<size_t>(segments * rings * 6));
    for (int j = 0; j < rings; ++j) {
        for (int i = 0; i < segments; ++i) {
            const uint32_t a = static_cast<uint32_t>(j) * columns + static_cast<uint32_t>(i);
            const uint32_t b = a + 1;
            const uint32_t d = static_cast<uint32_t>(j + 1) * columns + static_cast<uint32_t>(i);
            const uint32_t c = d + 1;
            indices.push_back(a);
            indices.push_back(b);
            indices.push_back(c);
            indices.push_back(a);
            indices.push_back(c);
            indices.push_back(d);
        }
    }
    return indices;
}

// SplitMix64, so the sky is identical on every launch.
struct SeededGenerator {
    uint64_t state;

    explicit SeededGenerator(uint64_t seed) : state(seed) {}

    uint64_t next() {
        state += 0x9E3779B97F4A7C15ull;
        uint64_t z = state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }

    double unit() { return static_cast<double>(next() >> 11) / static_cast<double>(1ull << 53); }
};

std::vector<StarVertex> starVertices(float radius, float screenScale) {
    struct Bucket {
        float size;
        float alpha;
        float r, g, b;
    };
    const Bucket buckets[] = {
        {1.0f, 0.30f, 0.62f, 0.72f, 0.88f},
        {1.3f, 0.52f, 0.78f, 0.85f, 0.96f},
        {1.8f, 0.78f, 0.92f, 0.95f, 1.00f},
        {2.6f, 1.00f, 1.00f, 1.00f, 1.00f},
        {1.6f, 0.60f, 1.00f, 0.86f, 0.70f},
    };

    SeededGenerator rng(0x5A77A112E5E0001ull);
    std::vector<StarVertex> stars;
    stars.reserve(5200 + 2600);

    auto append = [&](simd_float3 direction, int bucket) {
        const Bucket& b = buckets[bucket];
        StarVertex vertex;
        vertex.px = direction.x * radius;
        vertex.py = direction.y * radius;
        vertex.pz = direction.z * radius;
        vertex.r = b.r;
        vertex.g = b.g;
        vertex.b = b.b;
        vertex.a = b.alpha;
        vertex.size = b.size * screenScale / 2.0f;
        stars.push_back(vertex);
    };

    for (int index = 0; index < 5200; ++index) {
        const float z = static_cast<float>(rng.unit()) * 2.0f - 1.0f;
        const float theta = static_cast<float>(rng.unit()) * 2.0f * static_cast<float>(M_PI);
        const float r = std::sqrt(std::max(0.0f, 1.0f - z * z));
        const simd_float3 direction = simd_make_float3(r * std::cos(theta), z, r * std::sin(theta));

        const double magnitude = std::pow(rng.unit(), 2.6);
        int bucket = 0;
        if (magnitude < 0.42) bucket = 0;
        else if (magnitude < 0.72) bucket = 1;
        else if (magnitude < 0.90) bucket = 2;
        else if (magnitude < 0.985) bucket = 3;
        else bucket = rng.unit() < 0.55 ? 4 : 3;
        append(direction, bucket);
    }

    // Milky Way: a scatter around a tilted great circle.
    const float tiltAngle = static_cast<float>(M_PI / 3.1);
    const simd_float3 axis = simd_normalize(simd_make_float3(0.35f, 0.2f, 1.0f));
    for (int index = 0; index < 2600; ++index) {
        const float angle = static_cast<float>(rng.unit()) * 2.0f * static_cast<float>(M_PI);
        const double u1 = std::max(1e-9, rng.unit());
        const double u2 = rng.unit();
        double gaussian = std::sqrt(-2.0 * std::log(u1)) * std::cos(2.0 * M_PI * u2);
        gaussian = std::max(-2.5, std::min(2.5, gaussian));
        const float spread = static_cast<float>(gaussian) * 0.16f;

        simd_float3 point = simd_make_float3(std::cos(angle), std::sin(angle), spread);
        // Rotate around `axis` by `tiltAngle` (Rodrigues).
        const simd_float3 k = axis;
        const float c = std::cos(tiltAngle);
        const float s = std::sin(tiltAngle);
        point = point * c + simd_cross(k, point) * s + k * simd_dot(k, point) * (1.0f - c);
        append(simd_normalize(point), 0);
    }

    return stars;
}

}  // namespace

// MARK: - The view

@interface CaelusGlobeView () <MTKViewDelegate>
@end

@implementation CaelusGlobeView {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLLibrary> _library;

    id<MTLRenderPipelineState> _earthPipeline;
    id<MTLRenderPipelineState> _atmospherePipeline;
    id<MTLRenderPipelineState> _pointPipeline;
    id<MTLRenderPipelineState> _starPipeline;
    id<MTLRenderPipelineState> _lineAlphaPipeline;
    id<MTLRenderPipelineState> _lineAddPipeline;
    id<MTLDepthStencilState> _depthWrite;
    id<MTLDepthStencilState> _depthRead;
    id<MTLSamplerState> _sampler;

    id<MTLTexture> _dayTexture;
    id<MTLTexture> _nightTexture;
    id<MTLTexture> _specularTexture;

    id<MTLBuffer> _earthVertices;
    id<MTLBuffer> _earthIndices;
    NSUInteger _earthIndexCount;

    id<MTLBuffer> _atmosphereVertices;
    id<MTLBuffer> _atmosphereIndices;
    NSUInteger _atmosphereIndexCount;

    id<MTLBuffer> _starBuffer;
    NSUInteger _starCount;

    std::vector<Layer> _layers;
    LineBatch _orbit;
    LineBatch _groundPast;
    LineBatch _groundFuture;
    LineBatch _observerLines;
    LineBatch _horizonLine;
    LineBatch _pinLine;

    bool _observerVisible;
    bool _observerDotVisible;
    simd_float3 _observerDotPosition;

    bool _selectionValid;
    simd_float3 _selectionPosition;
    simd_float4 _selectionColor;

    caelus::SnapshotBuffer* _snapshotBuffer;
    std::mutex _stateMutex;
    RigState _rig;

    bool _showOrbit;
    bool _showGround;
    double _pointRadius;
    double _screenScale;
    float _lastFrameTime;
    float _frameTimeAccumulator;
    float _pulsePhase;

    // Input.
    NSPoint _lastDragLocation;
    BOOL _dragging;
    CGFloat _dragTravel;
    NSInteger _hoveredIndex;
    NSTimeInterval _lastHoverCheck;
    double _focusLatitude;
    double _focusLongitude;
}

- (instancetype)initWithFrame:(NSRect)frameRect device:(id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder*)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _device = MTLCreateSystemDefaultDevice();
    self.device = _device;
    _queue = [_device newCommandQueue];

    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.sampleCount = 4;
    self.clearColor = MTLClearColorMake(0.012, 0.020, 0.039, 1.0);
    self.preferredFramesPerSecond = 60;
    self.enableSetNeedsDisplay = NO;
    self.paused = NO;
    self.delegate = self;

    _rig.current = RigPose{22, 8, 3.5f};
    _rig.target = _rig.current;
    _pointRadius = 2.2;
    _screenScale = 2.0;
    _hoveredIndex = -1;
    _showOrbit = true;
    _showGround = true;
    _observerVisible = true;
    _observerDotVisible = false;
    _selectionValid = false;

    if (![self buildPipelines]) {
        return;
    }
    [self buildMeshes];
    [self buildStarField];
    [self buildObserverMarker];
}

// MARK: - Pipeline construction

- (id<MTLRenderPipelineState>)pipelineWithVertex:(NSString*)vertex
                                        fragment:(NSString*)fragment
                                      blending:(BOOL)additive
                                   writesDepth:(BOOL)writesDepth {
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [_library newFunctionWithName:vertex];
    descriptor.fragmentFunction = [_library newFunctionWithName:fragment];
    descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    descriptor.depthAttachmentPixelFormat = self.depthStencilPixelFormat;
    descriptor.rasterSampleCount = self.sampleCount;

    MTLRenderPipelineColorAttachmentDescriptor* attachment = descriptor.colorAttachments[0];
    attachment.blendingEnabled = YES;
    if (additive) {
        attachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOne;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOne;
    } else {
        attachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }

    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor
                                                                                  error:&error];
    if (pipeline == nil) {
        NSLog(@"Caelus: pipeline %@ failed: %@", vertex, error);
    }
    return pipeline;
}

- (BOOL)buildPipelines {
    NSError* error = nil;
    NSString* source = [NSString stringWithUTF8String:kCaelusShaderSource];
    _library = [_device newLibraryWithSource:source options:nil error:&error];
    if (_library == nil) {
        NSLog(@"Caelus: shader compilation failed: %@", error);
        return NO;
    }

    _earthPipeline = [self pipelineWithVertex:@"earth_vertex" fragment:@"earth_fragment"
                                     blending:NO writesDepth:YES];
    _atmospherePipeline = [self pipelineWithVertex:@"earth_vertex" fragment:@"atmosphere_fragment"
                                          blending:YES writesDepth:NO];
    _pointPipeline = [self pipelineWithVertex:@"satellite_vertex" fragment:@"satellite_fragment"
                                     blending:YES writesDepth:NO];
    _starPipeline = [self pipelineWithVertex:@"star_vertex" fragment:@"satellite_fragment"
                                    blending:YES writesDepth:NO];
    _lineAlphaPipeline = [self pipelineWithVertex:@"line_vertex" fragment:@"line_fragment"
                                         blending:NO writesDepth:NO];
    _lineAddPipeline = [self pipelineWithVertex:@"line_vertex" fragment:@"line_fragment"
                                       blending:YES writesDepth:NO];

    MTLDepthStencilDescriptor* write = [MTLDepthStencilDescriptor new];
    write.depthCompareFunction = MTLCompareFunctionLessEqual;
    write.depthWriteEnabled = YES;
    _depthWrite = [_device newDepthStencilStateWithDescriptor:write];

    MTLDepthStencilDescriptor* read = [MTLDepthStencilDescriptor new];
    read.depthCompareFunction = MTLCompareFunctionLessEqual;
    read.depthWriteEnabled = NO;
    _depthRead = [_device newDepthStencilStateWithDescriptor:read];

    MTLSamplerDescriptor* sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.mipFilter = MTLSamplerMipFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [_device newSamplerStateWithDescriptor:sampler];

    return _earthPipeline != nil && _pointPipeline != nil && _lineAddPipeline != nil;
}

// MARK: - Meshes and textures

- (void)buildMeshes {
    const std::vector<EarthVertex> vertices = sphereVertices(1.0f, 256, 128);
    const std::vector<uint32_t> indices = sphereIndices(256, 128);
    _earthVertices = [_device newBufferWithBytes:vertices.data()
                                          length:vertices.size() * sizeof(EarthVertex)
                                         options:MTLResourceStorageModeShared];
    _earthIndices = [_device newBufferWithBytes:indices.data()
                                         length:indices.size() * sizeof(uint32_t)
                                        options:MTLResourceStorageModeShared];
    _earthIndexCount = indices.size();

    const std::vector<EarthVertex> shell = sphereVertices(1.032f, 160, 80);
    const std::vector<uint32_t> shellIndices = sphereIndices(160, 80);
    _atmosphereVertices = [_device newBufferWithBytes:shell.data()
                                               length:shell.size() * sizeof(EarthVertex)
                                              options:MTLResourceStorageModeShared];
    _atmosphereIndices = [_device newBufferWithBytes:shellIndices.data()
                                              length:shellIndices.size() * sizeof(uint32_t)
                                             options:MTLResourceStorageModeShared];
    _atmosphereIndexCount = shellIndices.size();

    _dayTexture = [self loadTextureNamed:@"EarthDay"];
    _nightTexture = [self loadTextureNamed:@"EarthNight"];
    _specularTexture = [self loadTextureNamed:@"EarthSpecular"];
}

- (id<MTLTexture>)loadTextureNamed:(NSString*)name {
    NSBundle* bundle = [NSBundle mainBundle];
    NSURL* url = [bundle URLForResource:name withExtension:@"jpg" subdirectory:@"Textures"];
    if (url == nil) url = [bundle URLForResource:name withExtension:@"jpg"];
    if (url == nil) {
        NSLog(@"Caelus: missing texture %@", name);
        return nil;
    }

    NSImage* image = [[NSImage alloc] initWithContentsOfURL:url];
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (cgImage == NULL) return nil;

    const size_t width = CGImageGetWidth(cgImage);
    const size_t height = CGImageGetHeight(cgImage);
    std::vector<uint8_t> pixels(width * height * 4);

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.data(), width, height, 8,
                                                 width * 4, space,
                                                 static_cast<CGBitmapInfo>(
                                                     kCGImageAlphaPremultipliedLast) |
                                                     kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;

    // Keep the image's top row first, so texture v = 0 is the north pole.
    CGContextTranslateCTM(context, 0, static_cast<CGFloat>(height));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                           width:width
                                                          height:height
                                                       mipmapped:YES];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:pixels.data()
               bytesPerRow:width * 4];

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit generateMipmapsForTexture:texture];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    return texture;
}

- (void)buildStarField {
    const std::vector<StarVertex> stars =
        starVertices(70.0f, static_cast<float>(_screenScale));
    _starBuffer = [_device newBufferWithBytes:stars.data()
                                       length:stars.size() * sizeof(StarVertex)
                                      options:MTLResourceStorageModeShared];
    _starCount = stars.size();
}

- (void)buildObserverMarker {
    // Rebuilt on every site change; the buffers are replaced wholesale.
}

// MARK: - Public surface

- (void)rebuildLayers:(const std::map<caelus::SatelliteGroup, std::vector<size_t>>&)renderIndices {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _layers.clear();

    for (caelus::SatelliteGroup group : caelus::renderPriority()) {
        const auto found = renderIndices.find(group);
        if (found == renderIndices.end() || found->second.empty()) continue;

        Layer layer;
        layer.group = group;
        layer.indices = found->second;
        layer.count = found->second.size();
        layer.color = colorForGroup(group);
        layer.pointScale = pointScaleForGroup(group);
        layer.haloAlpha = group == caelus::SatelliteGroup::starlink ? 0.05f : 0.11f;
        layer.visible = true;
        layer.buffer = [_device newBufferWithLength:layer.count * sizeof(simd_float4)
                                            options:MTLResourceStorageModeShared];
        float* contents = static_cast<float*>(layer.buffer.contents);
        for (size_t index = 0; index < layer.count; ++index) {
            contents[index * 4 + 0] = NAN;
            contents[index * 4 + 1] = NAN;
            contents[index * 4 + 2] = NAN;
            contents[index * 4 + 3] = 1.0f;
        }
        _layers.push_back(std::move(layer));
    }
}

- (void)setGroup:(caelus::SatelliteGroup)group visible:(BOOL)visible {
    std::lock_guard<std::mutex> guard(_stateMutex);
    for (Layer& layer : _layers) {
        if (layer.group == group) layer.visible = visible;
    }
}

- (void)setPointRadius:(double)radius {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _pointRadius = radius;
    _screenScale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 2.0;
}

- (void)attachSnapshotBuffer:(caelus::SnapshotBuffer*)buffer {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _snapshotBuffer = buffer;
}

- (void)setObserverSite:(const caelus::ObserverSite&)site {
    std::lock_guard<std::mutex> guard(_stateMutex);
    [self rebuildObserverLines:site];
}

- (void)setObserverVisible:(BOOL)visible {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _observerVisible = visible;
}

- (void)clearTrack {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _orbit.runs.clear();
    _groundPast.runs.clear();
    _groundFuture.runs.clear();
    _selectionValid = false;
}

- (void)setSelectionPosition:(const caelus::sky::Vec3&)position valid:(BOOL)valid
                      color:(NSColor*)color {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _selectionValid = valid;
    _selectionPosition = scenePoint(position);
    _selectionColor = simd_make_float4(static_cast<float>(color.redComponent),
                                       static_cast<float>(color.greenComponent),
                                       static_cast<float>(color.blueComponent), 1.0f);
}

- (void)focusLatitude:(double)latitude longitude:(double)longitude distance:(float)distance {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _rig.target.latitude = std::max(-89.0f, std::min(89.0f, static_cast<float>(latitude)));
    _rig.target.longitude = static_cast<float>(longitude);
    if (distance > 0) {
        _rig.target.distance = std::max(1.055f, std::min(14.0f, distance));
    }
}

- (void)resetCamera {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _rig.target = RigPose{22, 8, 3.5f};
}

- (float)cameraDistance {
    std::lock_guard<std::mutex> guard(_stateMutex);
    return _rig.current.distance;
}

// MARK: - Tracks

- (void)updateTrackSamples:(const std::vector<caelus::TrackSample>&)samples
                     color:(NSColor*)color
                 showOrbit:(BOOL)showOrbit
                showGround:(BOOL)showGround {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _showOrbit = showOrbit;
    _showGround = showGround;

    const simd_float4 rgba = simd_make_float4(static_cast<float>(color.redComponent),
                                              static_cast<float>(color.greenComponent),
                                              static_cast<float>(color.blueComponent), 1.0f);

    // Orbit: one vertex per sample, split wherever the samples jump.
    std::vector<LineVertex> orbitVertices;
    std::vector<std::pair<NSUInteger, NSUInteger>> orbitRuns;
    auto beginRun = [&] { return orbitVertices.size(); };
    auto finishRun = [&](size_t start) {
        if (orbitVertices.size() - start > 1) {
            orbitRuns.emplace_back(start, orbitVertices.size() - start);
        }
    };

    size_t runStart = beginRun();
    simd_float3 previous = simd_make_float3(0, 0, 0);
    for (size_t index = 0; index < samples.size(); ++index) {
        const caelus::TrackSample& sample = samples[index];
        const caelus::sky::Vec3 position =
            caelus::GeoMath::scenePosition(sample.latitude, sample.longitude, sample.altitudeKm);
        const simd_float3 point = scenePoint(position);
        if (index > 0 && simd_distance(previous, point) > 0.35f) {
            finishRun(runStart);
            runStart = beginRun();
        }
        orbitVertices.push_back(LineVertex{point.x, point.y, point.z, rgba.x, rgba.y, rgba.z,
                                           rgba.w * 0.85f});
        previous = point;
    }
    finishRun(runStart);
    _orbit.buffer = [self bufferForVertices:orbitVertices];
    _orbit.runs = orbitRuns;
    _orbit.visible = showOrbit;

    // Ground track: past dim, future bright, split at the antimeridian.
    std::vector<LineVertex> pastVertices;
    std::vector<LineVertex> futureVertices;
    std::vector<std::pair<NSUInteger, NSUInteger>> pastRuns;
    std::vector<std::pair<NSUInteger, NSUInteger>> futureRuns;

    auto appendGround = [&](const std::vector<caelus::TrackSample>& side,
                            std::vector<LineVertex>& vertices,
                            std::vector<std::pair<NSUInteger, NSUInteger>>& runs,
                            float alpha) {
        std::vector<caelus::sky::LatLonAlt> points;
        points.reserve(side.size());
        for (const caelus::TrackSample& sample : side) {
            points.push_back(caelus::sky::LatLonAlt{sample.latitude, sample.longitude, 0});
        }
        for (const auto& run : caelus::GeoMath::splitAtAntimeridian(points)) {
            if (run.size() < 2) continue;
            const NSUInteger start = vertices.size();
            for (const caelus::sky::LatLonAlt& point : run) {
                const caelus::sky::Vec3 position = caelus::GeoMath::scenePositionOnRadius(
                    point.lat, point.lon, 1.0025);
                const simd_float3 scene = scenePoint(position);
                vertices.push_back(LineVertex{scene.x, scene.y, scene.z, rgba.x, rgba.y,
                                              rgba.z, alpha});
            }
            runs.emplace_back(start, run.size());
        }
    };

    std::vector<caelus::TrackSample> past;
    std::vector<caelus::TrackSample> future;
    for (const caelus::TrackSample& sample : samples) {
        if (sample.offsetMinutes <= 0) past.push_back(sample);
        if (sample.offsetMinutes >= 0) future.push_back(sample);
    }
    appendGround(past, pastVertices, pastRuns, 0.22f);
    appendGround(future, futureVertices, futureRuns, 0.95f);

    _groundPast.buffer = [self bufferForVertices:pastVertices];
    _groundPast.runs = pastRuns;
    _groundPast.visible = showGround;
    _groundPast.additive = false;

    _groundFuture.buffer = [self bufferForVertices:futureVertices];
    _groundFuture.runs = futureRuns;
    _groundFuture.visible = showGround;
    _groundFuture.additive = true;
}

- (id<MTLBuffer>)bufferForVertices:(const std::vector<LineVertex>&)vertices {
    if (vertices.empty()) return nil;
    return [_device newBufferWithBytes:vertices.data()
                                length:vertices.size() * sizeof(LineVertex)
                               options:MTLResourceStorageModeShared];
}

// MARK: - Observer marker

- (void)rebuildObserverLines:(const caelus::ObserverSite&)site {
    const caelus::sky::Vec3 unit = caelus::GeoMath::unitVector(site.latitude, site.longitude);
    const simd_float3 center = scenePoint(unit);

    auto circle = [&](float angularRadiusDegrees, float radius, int segments) {
        std::vector<LineVertex> vertices;
        const simd_float3 up = simd_normalize(simd_make_float3(0, 1, 0) -
                                              center * simd_dot(center, simd_make_float3(0, 1, 0)));
        const simd_float3 side = simd_normalize(simd_cross(center, up));
        const float angular = angularRadiusDegrees * static_cast<float>(M_PI) / 180.0f;
        const float cosA = std::cos(angular);
        const float sinA = std::sin(angular);
        for (int index = 0; index <= segments; ++index) {
            const float theta =
                static_cast<float>(index) / static_cast<float>(segments) *
                2.0f * static_cast<float>(M_PI);
            const simd_float3 direction =
                center * cosA + (up * std::cos(theta) + side * std::sin(theta)) * sinA;
            vertices.push_back(LineVertex{direction.x * radius, direction.y * radius,
                                          direction.z * radius, 0.31f, 0.70f, 1.0f, 1.0f});
        }
        return vertices;
    };

    auto applyAlpha = [](std::vector<LineVertex>& vertices, float alpha) {
        for (LineVertex& vertex : vertices) vertex.a = alpha;
    };

    std::vector<LineVertex> ring = circle(1.1f, 1.0035f, 72);
    applyAlpha(ring, 0.85f);
    _observerLines.buffer = [self bufferForVertices:ring];
    _observerLines.runs = ring.empty() ? std::vector<std::pair<NSUInteger, NSUInteger>>{}
                                       : std::vector<std::pair<NSUInteger, NSUInteger>>{
                                             {0, ring.size()}};
    _observerLines.visible = true;

    std::vector<LineVertex> horizon = circle(90.0f, 1.0015f, 180);
    applyAlpha(horizon, 0.10f);
    _horizonLine.buffer = [self bufferForVertices:horizon];
    _horizonLine.runs = horizon.empty() ? std::vector<std::pair<NSUInteger, NSUInteger>>{}
                                        : std::vector<std::pair<NSUInteger, NSUInteger>>{
                                              {0, horizon.size()}};
    _horizonLine.visible = true;

    std::vector<LineVertex> pin = {
        LineVertex{center.x * 1.0f, center.y * 1.0f, center.z * 1.0f, 0.31f, 0.70f, 1.0f, 0.55f},
        LineVertex{center.x * 1.045f, center.y * 1.045f, center.z * 1.045f, 0.31f, 0.70f, 1.0f,
                   0.55f},
    };
    _pinLine.buffer = [self bufferForVertices:pin];
    _pinLine.runs = {{0, 2}};
    _pinLine.visible = true;

    _observerDotPosition = center * 1.045f;
    _observerDotVisible = true;
}

// MARK: - Per-frame update

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView*)view {
    [self renderToView:view];
}

- (void)renderToView:(MTKView*)view {
    const float now = static_cast<float>(CACurrentMediaTime());
    const float dt = _lastFrameTime == 0 ? 1.0f / 60.0f
                                         : std::min(0.25f, std::max(0.0f, now - _lastFrameTime));
    _lastFrameTime = now;
    [self stepCamera:dt];
    _pulsePhase = std::fmod(_pulsePhase + dt, 3.8f);

    std::lock_guard<std::mutex> guard(_stateMutex);

    FrameUniforms uniforms = [self frameUniformsForSize:view.drawableSize];
    [self updateSatelliteBuffers];

    MTLRenderPassDescriptor* pass = view.currentRenderPassDescriptor;
    if (pass == nil) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [self encodeScene:encoder uniforms:&uniforms size:view.drawableSize];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (FrameUniforms)frameUniformsForSize:(CGSize)size {
    const float aspect = static_cast<float>(size.width / std::max<CGFloat>(1, size.height));

    const RigPose pose = _rig.current;
    const caelus::sky::Vec3 unit = caelus::GeoMath::unitVector(pose.latitude, pose.longitude);
    const simd_float3 eye = scenePoint(unit) * pose.distance;

    simd_float3 up = simd_make_float3(0, 1, 0) - scenePoint(unit) * scenePoint(unit).y;
    if (simd_length(up) < 1e-4f) up = simd_make_float3(0, 0, 1);
    up = simd_normalize(up);

    const simd_float4x4 view = lookAtMatrix(eye, simd_make_float3(0, 0, 0), up);
    const simd_float4x4 projection = perspectiveMatrix(
        34.0f * static_cast<float>(M_PI) / 180.0f, aspect, 0.005f, 400.0f);

    FrameUniforms uniforms;
    uniforms.viewProjection = simd_mul(projection, view);
    const caelus::sky::Vec3 sun =
        caelus::SunCalculator::sceneDirection(caelus::sky::nowDate());
    uniforms.sunDirection = simd_make_float4(static_cast<float>(sun.x), static_cast<float>(sun.y),
                                             static_cast<float>(sun.z), 0);
    uniforms.cameraPosition = simd_make_float4(eye.x, eye.y, eye.z, 0);
    return uniforms;
}

- (void)encodeScene:(id<MTLRenderCommandEncoder>)encoder uniforms:(FrameUniforms*)uniforms
               size:(CGSize)size {
    [encoder setCullMode:MTLCullModeNone];

    // Stars: additive, no depth.
    if (_starPipeline != nil && _starCount > 0) {
        [encoder setRenderPipelineState:_starPipeline];
        [encoder setVertexBuffer:_starBuffer offset:0 atIndex:0];
        [encoder setVertexBytes:uniforms length:sizeof(FrameUniforms) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:_starCount];
    }

    // Earth.
    if (_earthPipeline != nil && _dayTexture != nil) {
        [encoder setRenderPipelineState:_earthPipeline];
        [encoder setDepthStencilState:_depthWrite];
        [encoder setCullMode:MTLCullModeBack];
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [encoder setVertexBuffer:_earthVertices offset:0 atIndex:0];
        [encoder setVertexBytes:uniforms length:sizeof(FrameUniforms) atIndex:1];
        [encoder setFragmentBytes:uniforms length:sizeof(FrameUniforms) atIndex:1];
        [encoder setFragmentTexture:_dayTexture atIndex:0];
        [encoder setFragmentTexture:_nightTexture atIndex:1];
        [encoder setFragmentTexture:_specularTexture atIndex:2];
        [encoder setFragmentSamplerState:_sampler atIndex:0];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:_earthIndexCount
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:_earthIndices
                     indexBufferOffset:0];

        // Atmosphere: additive, depth-tested but not depth-writing.
        [encoder setRenderPipelineState:_atmospherePipeline];
        [encoder setDepthStencilState:_depthRead];
        [encoder setVertexBuffer:_atmosphereVertices offset:0 atIndex:0];
        [encoder setVertexBytes:uniforms length:sizeof(FrameUniforms) atIndex:1];
        [encoder setFragmentBytes:uniforms length:sizeof(FrameUniforms) atIndex:1];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:_atmosphereIndexCount
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:_atmosphereIndices
                     indexBufferOffset:0];
    }

    // Satellites: core then halo, depth-tested against the globe.
    [encoder setRenderPipelineState:_pointPipeline];
    [encoder setDepthStencilState:_depthRead];
    for (const Layer& layer : _layers) {
        if (!layer.visible || layer.count == 0 || layer.buffer == nil) continue;

        PointUniforms point;
        point.viewProjection = uniforms->viewProjection;
        point.color = simd_make_float4(layer.color.x, layer.color.y, layer.color.z, 1.0f);
        point.pointSize = static_cast<float>(_pointRadius * layer.pointScale * _screenScale);
        [encoder setVertexBuffer:layer.buffer offset:0 atIndex:0];
        [encoder setVertexBytes:&point length:sizeof(PointUniforms) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:layer.count];

        PointUniforms halo = point;
        halo.color.w = layer.haloAlpha;
        halo.pointSize = point.pointSize * 2.35f;
        [encoder setVertexBytes:&halo length:sizeof(PointUniforms) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:layer.count];
    }

    // Tracks and ground station.
    auto drawBatch = [&](const LineBatch& batch) {
        if (!batch.visible || batch.buffer == nil || batch.runs.empty()) return;
        [encoder setRenderPipelineState:batch.additive ? _lineAddPipeline : _lineAlphaPipeline];
        [encoder setDepthStencilState:_depthRead];
        [encoder setVertexBuffer:batch.buffer offset:0 atIndex:0];
        [encoder setVertexBytes:uniforms length:sizeof(FrameUniforms) atIndex:1];
        for (const auto& run : batch.runs) {
            [encoder drawPrimitives:MTLPrimitiveTypeLineStrip
                        vertexStart:run.first
                        vertexCount:run.second];
        }
    };

    drawBatch(_orbit);
    drawBatch(_groundPast);
    drawBatch(_groundFuture);
    if (_observerVisible) {
        drawBatch(_observerLines);
        drawBatch(_horizonLine);
        drawBatch(_pinLine);

        if (_observerDotVisible) {
            PointUniforms dot;
            dot.viewProjection = uniforms->viewProjection;
            dot.color = simd_make_float4(0.31f, 0.70f, 1.0f, 0.9f);
            dot.pointSize = static_cast<float>(6.0 * _screenScale);
            simd_float4 position = simd_make_float4(_observerDotPosition.x, _observerDotPosition.y,
                                                    _observerDotPosition.z, 1.0f);
            [encoder setRenderPipelineState:_pointPipeline];
            [encoder setDepthStencilState:_depthRead];
            [encoder setVertexBytes:&position length:sizeof(position) atIndex:0];
            [encoder setVertexBytes:&dot length:sizeof(PointUniforms) atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
        }
    }

    // Selection marker: a pulsing glow pinned to the satellite.
    if (_selectionValid) {
        const float pulse = 0.5f + 0.5f * std::sin(_pulsePhase * 2.0f * static_cast<float>(M_PI) /
                                                   1.9f);
        const float base = static_cast<float>(14.0 * _screenScale) *
                           std::max(1.0f, _rig.current.distance / 3.5f);

        simd_float4 position = simd_make_float4(_selectionPosition.x, _selectionPosition.y,
                                                _selectionPosition.z, 1.0f);
        [encoder setVertexBytes:&position length:sizeof(position) atIndex:0];

        PointUniforms glow;
        glow.viewProjection = uniforms->viewProjection;
        glow.color = simd_make_float4(_selectionColor.x, _selectionColor.y, _selectionColor.z,
                                      0.35f + 0.25f * pulse);
        glow.pointSize = base * (1.0f + 0.45f * pulse);
        [encoder setRenderPipelineState:_pointPipeline];
        [encoder setDepthStencilState:_depthRead];
        [encoder setVertexBytes:&glow length:sizeof(PointUniforms) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];

        PointUniforms core = glow;
        core.color.w = 1.0f;
        core.pointSize = base * 0.32f;
        [encoder setVertexBytes:&core length:sizeof(PointUniforms) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
    }
}

// MARK: - Snapshot interpolation

- (void)updateSatelliteBuffers {
    if (_snapshotBuffer == nullptr || _layers.empty()) return;

    const auto pair = _snapshotBuffer->pair();
    const caelus::SatelliteSnapshot& current = pair.second;
    const caelus::SatelliteSnapshot& previous = pair.first;
    if (current.count() == 0) return;

    const double now = caelus::sky::nowDate();
    const double span = current.time - previous.time;
    float alpha = 1.0f;
    if (span > 0.01) {
        alpha = static_cast<float>((now - current.time) / span);
        alpha = std::min(1.0f, std::max(0.0f, alpha));
    }
    const bool canBlend = previous.count() == current.count() && previous.time > -1.0e11;

    for (Layer& layer : _layers) {
        if (!layer.visible || layer.buffer == nil) continue;
        float* contents = static_cast<float*>(layer.buffer.contents);
        const auto& indices = layer.indices;

        for (size_t index = 0; index < layer.count; ++index) {
            const size_t catalogIndex = indices[index];
            float* slot = contents + index * 4;
            if (catalogIndex >= current.count() || !current.valid[catalogIndex]) {
                slot[0] = slot[1] = slot[2] = NAN;
                continue;
            }
            const caelus::sky::Vec3 next = current.positions[catalogIndex];
            if (canBlend && catalogIndex < previous.count() &&
                previous.valid[catalogIndex]) {
                const caelus::sky::Vec3 prior = previous.positions[catalogIndex];
                slot[0] = static_cast<float>(prior.x + (next.x - prior.x) * alpha);
                slot[1] = static_cast<float>(prior.y + (next.y - prior.y) * alpha);
                slot[2] = static_cast<float>(prior.z + (next.z - prior.z) * alpha);
            } else {
                slot[0] = static_cast<float>(next.x);
                slot[1] = static_cast<float>(next.y);
                slot[2] = static_cast<float>(next.z);
            }
        }
    }
}

// MARK: - Camera

- (void)stepCamera:(float)dt {
    std::lock_guard<std::mutex> guard(_stateMutex);
    const float rate = 13.0f;
    const float k = 1.0f - std::exp(-rate * dt);

    _rig.current.latitude += (_rig.target.latitude - _rig.current.latitude) * k;
    _rig.current.distance += (_rig.target.distance - _rig.current.distance) * k;

    float delta = _rig.target.longitude - _rig.current.longitude;
    while (delta > 180.0f) delta -= 360.0f;
    while (delta < -180.0f) delta += 360.0f;
    _rig.current.longitude += delta * k;
    while (_rig.current.longitude > 180.0f) _rig.current.longitude -= 360.0f;
    while (_rig.current.longitude < -180.0f) _rig.current.longitude += 360.0f;
}

- (void)orbitByDX:(CGFloat)dx dy:(CGFloat)dy {
    std::lock_guard<std::mutex> guard(_stateMutex);
    const float height = std::max(200.0f, static_cast<float>(self.bounds.size.height));
    float perPixel = (std::max(0.05f, _rig.current.distance - 1.0f) * 34.0f) / height;
    perPixel = std::min(1.6f, std::max(0.005f, perPixel));

    _rig.target.latitude += static_cast<float>(dy) * perPixel;
    _rig.target.latitude = std::min(89.0f, std::max(-89.0f, _rig.target.latitude));

    const float cosine = std::max(0.25f, std::cos(_rig.target.latitude *
                                                  static_cast<float>(M_PI) / 180.0f));
    _rig.target.longitude -= static_cast<float>(dx) * perPixel / cosine;
}

- (void)zoomBy:(double)factor {
    std::lock_guard<std::mutex> guard(_stateMutex);
    _rig.target.distance = std::max(1.055f, std::min(14.0f,
                                                     static_cast<float>(_rig.current.distance *
                                                                        factor)));
}

// MARK: - Picking

- (NSInteger)pickAtPoint:(NSPoint)point {
    std::lock_guard<std::mutex> guard(_stateMutex);
    if (_snapshotBuffer == nullptr) return -1;

    const caelus::SatelliteSnapshot current = _snapshotBuffer->pair().second;
    if (current.count() == 0) return -1;

    const NSSize bounds = self.bounds.size;
    const FrameUniforms uniforms =
        [self frameUniformsForSize:CGSizeMake(std::max<CGFloat>(1, bounds.width),
                                              std::max<CGFloat>(1, bounds.height))];

    const caelus::sky::Vec3 unit = caelus::GeoMath::unitVector(_rig.current.latitude,
                                                               _rig.current.longitude);
    const simd_float3 cameraDirection = simd_normalize(scenePoint(unit));
    const float horizon = 1.0f / _rig.current.distance;

    NSInteger best = -1;
    CGFloat bestDistance = std::numeric_limits<CGFloat>::max();
    const CGFloat pickRadius = 13.0;

    for (const Layer& layer : _layers) {
        if (!layer.visible) continue;
        for (size_t index : layer.indices) {
            if (index >= current.count() || !current.valid[index]) continue;
            const simd_float3 position = scenePoint(current.positions[index]);
            if (simd_dot(simd_normalize(position), cameraDirection) < horizon) continue;

            const simd_float4 clip =
                simd_mul(uniforms.viewProjection,
                         simd_make_float4(position.x, position.y, position.z, 1.0f));
            if (clip.w <= 0) continue;
            const float ndcX = clip.x / clip.w;
            const float ndcY = clip.y / clip.w;
            const float ndcZ = clip.z / clip.w;
            if (ndcZ < 0 || ndcZ > 1) continue;

            const CGFloat screenX = (ndcX * 0.5f + 0.5f) * bounds.width;
            const CGFloat screenY = (ndcY * 0.5f + 0.5f) * bounds.height;
            const CGFloat dx = screenX - point.x;
            const CGFloat dy = screenY - point.y;
            const CGFloat distance = std::sqrt(dx * dx + dy * dy);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = static_cast<NSInteger>(index);
            }
        }
    }
    return bestDistance <= pickRadius ? best : -1;
}

// MARK: - Input

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea* area in self.trackingAreas) [self removeTrackingArea:area];
    NSTrackingArea* area =
        [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                     options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                              NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
                                       owner:self
                                    userInfo:nil];
    [self addTrackingArea:area];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds
                 cursor:_hoveredIndex >= 0 ? [NSCursor pointingHandCursor] : [NSCursor arrowCursor]];
}

- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    _lastDragLocation = [self convertPoint:event.locationInWindow fromView:nil];
    _dragTravel = 0;
    _dragging = YES;
}

- (void)mouseDragged:(NSEvent*)event {
    const NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat dx = location.x - _lastDragLocation.x;
    const CGFloat dy = location.y - _lastDragLocation.y;
    _lastDragLocation = location;
    _dragTravel += std::fabs(dx) + std::fabs(dy);
    if (_dragTravel > 2) [self setHoveredIndex:-1];
    [self orbitByDX:dx dy:dy];
}

- (void)mouseUp:(NSEvent*)event {
    _dragging = NO;
    if (_dragTravel > 2) return;

    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.clickCount >= 2) {
        if ([self surfaceCoordinate:point latitude:&_focusLatitude longitude:&_focusLongitude]) {
            [self.globeDelegate globeView:self
                 didRequestFocusLatitude:_focusLatitude
                                longitude:_focusLongitude];
        }
    } else {
        const NSInteger index = [self pickAtPoint:point];
        [self.globeDelegate globeView:self didSelectIndex:index];
    }
}

- (void)mouseMoved:(NSEvent*)event {
    const NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now - _lastHoverCheck < 0.09) return;
    _lastHoverCheck = now;
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self setHoveredIndex:[self pickAtPoint:point]];
}

- (void)mouseExited:(NSEvent*)event {
    [self setHoveredIndex:-1];
}

- (void)setHoveredIndex:(NSInteger)index {
    if (index == _hoveredIndex) return;
    _hoveredIndex = index;
    [[self window] invalidateCursorRectsForView:self];
    [self.globeDelegate globeView:self didHoverIndex:index];
}

- (void)scrollWheel:(NSEvent*)event {
    const CGFloat raw = event.scrollingDeltaY;
    if (raw == 0) return;
    const double delta = event.hasPreciseScrollingDeltas ? raw * 0.006 : raw * 0.10;
    [self zoomBy:std::exp(-delta)];
}

- (void)magnifyWithEvent:(NSEvent*)event {
    [self zoomBy:1.0 / (1.0 + std::max(-0.8, event.magnification))];
}

- (void)smartMagnifyWithEvent:(NSEvent*)event {
    [self.globeDelegate globeViewDidRequestReset:self];
}

- (BOOL)surfaceCoordinate:(NSPoint)point latitude:(double*)latitude longitude:(double*)longitude {
    std::lock_guard<std::mutex> guard(_stateMutex);
    const NSSize bounds = self.bounds.size;
    const FrameUniforms uniforms =
        [self frameUniformsForSize:CGSizeMake(std::max<CGFloat>(1, bounds.width),
                                              std::max<CGFloat>(1, bounds.height))];
    const simd_float4x4 inverse = simd_inverse(uniforms.viewProjection);

    const float ndcX = static_cast<float>((point.x / bounds.width) * 2.0 - 1.0);
    const float ndcY = static_cast<float>((point.y / bounds.height) * 2.0 - 1.0);

    simd_float4 near = simd_mul(inverse, simd_make_float4(ndcX, ndcY, 0.0f, 1.0f));
    simd_float4 far = simd_mul(inverse, simd_make_float4(ndcX, ndcY, 1.0f, 1.0f));
    near /= near.w;
    far /= far.w;

    const simd_float3 origin = simd_make_float3(near.x, near.y, near.z);
    const simd_float3 direction = simd_normalize(simd_make_float3(far.x, far.y, far.z) - origin);
    const float b = simd_dot(origin, direction);
    const float c = simd_dot(origin, origin) - 1.0f;
    const float discriminant = b * b - c;
    if (discriminant < 0) return NO;
    const float t = -b - std::sqrt(discriminant);
    if (t <= 0) return NO;

    const simd_float3 hit = origin + direction * t;
    const auto [lat, lon] = caelus::GeoMath::latLon(
        caelus::sky::Vec3(hit.x, hit.y, hit.z));
    *latitude = lat;
    *longitude = lon;
    return YES;
}

// MARK: - Snapshot

- (NSImage*)snapshotImage {
    const CGSize size = self.drawableSize;
    if (size.width < 1 || size.height < 1) return nil;

    MTLTextureDescriptor* colorDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                     width:static_cast<NSUInteger>(size.width)
                                    height:static_cast<NSUInteger>(size.height)
                                 mipmapped:NO];
    colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorDescriptor.storageMode = MTLStorageModePrivate;

    MTLTextureDescriptor* msaaDescriptor = [colorDescriptor copy];
    msaaDescriptor.textureType = MTLTextureType2DMultisample;
    msaaDescriptor.sampleCount = self.sampleCount;
    msaaDescriptor.storageMode = MTLStorageModePrivate;

    MTLTextureDescriptor* depthDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                           width:static_cast<NSUInteger>(size.width)
                                                          height:static_cast<NSUInteger>(size.height)
                                                       mipmapped:NO];
    depthDescriptor.textureType = MTLTextureType2DMultisample;
    depthDescriptor.sampleCount = self.sampleCount;
    depthDescriptor.usage = MTLTextureUsageRenderTarget;
    depthDescriptor.storageMode = MTLStorageModePrivate;

    id<MTLTexture> msaa = [_device newTextureWithDescriptor:msaaDescriptor];
    id<MTLTexture> resolve = [_device newTextureWithDescriptor:colorDescriptor];
    id<MTLTexture> depth = [_device newTextureWithDescriptor:depthDescriptor];
    if (msaa == nil || resolve == nil || depth == nil) return nil;

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = msaa;
    pass.colorAttachments[0].resolveTexture = resolve;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    pass.colorAttachments[0].clearColor = self.clearColor;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;

    std::lock_guard<std::mutex> guard(_stateMutex);
    FrameUniforms uniforms = [self frameUniformsForSize:size];
    [self updateSatelliteBuffers];

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [self encodeScene:encoder uniforms:&uniforms size:size];
    [encoder endEncoding];

    id<MTLBuffer> readback = [_device newBufferWithLength:size.width * size.height * 4
                                                  options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:resolve
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(static_cast<NSUInteger>(size.width),
                                      static_cast<NSUInteger>(size.height), 1)
                 toBuffer:readback
        destinationOffset:0
   destinationBytesPerRow:static_cast<NSUInteger>(size.width) * 4
 destinationBytesPerImage:size.width * size.height * 4];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:static_cast<NSInteger>(size.width)
                      pixelsHigh:static_cast<NSInteger>(size.height)
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                    bytesPerRow:static_cast<NSInteger>(size.width) * 4
                   bitsPerPixel:32];
    // Metal resolves into BGRA; NSBitmapImageRep reads RGBA. Swapping here keeps
    // shader-authored colours (sky, atmosphere, stars) from turning orange.
    const uint8_t* source = static_cast<const uint8_t*>(readback.contents);
    uint8_t* destination = static_cast<uint8_t*>(rep.bitmapData);
    const size_t pixelCount = size.width * size.height;
    for (size_t index = 0; index < pixelCount; ++index) {
        destination[index * 4 + 0] = source[index * 4 + 2];
        destination[index * 4 + 1] = source[index * 4 + 1];
        destination[index * 4 + 2] = source[index * 4 + 0];
        destination[index * 4 + 3] = source[index * 4 + 3];
    }
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(size.width, size.height)];
    [image addRepresentation:rep];
    return image;
}

@end
