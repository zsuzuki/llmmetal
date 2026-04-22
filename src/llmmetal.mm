#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include "llmmetal/llmmetal.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <span>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace llmmetal {
struct Backend;
}

@interface InputWindow : NSWindow
@property(nonatomic, assign) llmmetal::Backend* backendPtr;
@end

@interface LlmMetalViewDelegate : NSObject<NSApplicationDelegate, MTKViewDelegate>
- (instancetype)initWithBackend:(llmmetal::Backend*)backend;
@end

static size_t llmmetal_key_index(llmmetal::Key key) {
  return static_cast<size_t>(key);
}

static llmmetal::Key llmmetal_map_key_code(unsigned short key_code) {
  switch (key_code) {
    case 53: return llmmetal::Key::escape;
    case 49: return llmmetal::Key::space;
    case 123: return llmmetal::Key::left;
    case 124: return llmmetal::Key::right;
    case 125: return llmmetal::Key::down;
    case 126: return llmmetal::Key::up;
    case 0: return llmmetal::Key::a;
    case 2: return llmmetal::Key::d;
    case 1: return llmmetal::Key::s;
    case 13: return llmmetal::Key::w;
    case 12: return llmmetal::Key::q;
    case 14: return llmmetal::Key::e;
    case 15: return llmmetal::Key::r;
    case 3: return llmmetal::Key::f;
    case 6: return llmmetal::Key::z;
    case 7: return llmmetal::Key::x;
    case 8: return llmmetal::Key::c;
    case 9: return llmmetal::Key::v;
    default: return llmmetal::Key::unknown;
  }
}

namespace llmmetal {

namespace {

struct Uniforms {
  float mvp[16];
  float color[4];
  uint32_t use_texture;
};

struct GpuVertex {
  float px;
  float py;
  float pz;
  float cr;
  float cg;
  float cb;
  float ca;
  float u;
  float v;
};

struct CachedTextTexture {
  TextureHandle handle {};
  Vec2 size {};
  std::uint64_t last_used = 0;
};

constexpr size_t kMaxTextCacheEntries = 256;

constexpr char kShaderSource[] = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
  float3 position [[attribute(0)]];
  float4 color [[attribute(1)]];
  float2 uv [[attribute(2)]];
};

struct Uniforms {
  float4x4 mvp;
  float4 color;
  uint use_texture;
};

struct VertexOut {
  float4 position [[position]];
  float4 color;
  float2 uv;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]], constant Uniforms& uniforms [[buffer(1)]]) {
  VertexOut out;
  out.position = uniforms.mvp * float4(in.position, 1.0);
  out.color = in.color * uniforms.color;
  out.uv = in.uv;
  return out;
}

fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]],
    texture2d<float> color_texture [[texture(0)]]) {
  constexpr sampler linear_sampler(address::clamp_to_edge, filter::linear);
  float4 base = in.color;
  if (uniforms.use_texture != 0 && color_texture.get_width() > 0) {
    base *= color_texture.sample(linear_sampler, in.uv);
  }
  return base;
}
)";

constexpr float kPi = 3.14159265358979323846f;

Vec3 operator-(Vec3 a, Vec3 b) {
  return {a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 operator*(Vec3 a, float s) {
  return {a.x * s, a.y * s, a.z * s};
}

float dot(Vec3 a, Vec3 b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 cross(Vec3 a, Vec3 b) {
  return {
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
  };
}

Vec3 normalize(Vec3 v) {
  const float len = std::sqrt(dot(v, v));
  if (len <= 1.0e-6f) {
    return {0.0f, 0.0f, 0.0f};
  }
  return v * (1.0f / len);
}

std::array<float, 16> to_column_major(const Mat4& m) {
  std::array<float, 16> out {};
  std::copy(std::begin(m.m), std::end(m.m), out.begin());
  return out;
}

float& mat_at(Mat4& m, int col, int row) {
  return m.m[col * 4 + row];
}

float mat_at(const Mat4& m, int col, int row) {
  return m.m[col * 4 + row];
}

GpuVertex make_vertex(Vec3 pos, Color color, Vec2 uv = {}) {
  return {pos.x, pos.y, pos.z, color.r, color.g, color.b, color.a, uv.x, uv.y};
}

TextureHandle make_handle(uint32_t value) {
  return TextureHandle {value};
}

std::string path_to_utf8(const std::filesystem::path& path) {
  return path.generic_string();
}

std::string make_text_cache_key(std::string_view text, float font_size, Color color) {
  std::ostringstream oss;
  oss << text << '\n'
      << font_size << '\n'
      << color.r << ',' << color.g << ',' << color.b << ',' << color.a;
  return oss.str();
}

bool read_ppm_token(std::istream& in, std::string& token) {
  token.clear();
  while (true) {
    int ch = in.peek();
    if (ch == EOF) {
      return false;
    }
    if (std::isspace(ch) != 0) {
      in.get();
      continue;
    }
    if (ch == '#') {
      std::string ignored;
      std::getline(in, ignored);
      continue;
    }
    break;
  }

  while (true) {
    int ch = in.peek();
    if (ch == EOF || std::isspace(ch) != 0 || ch == '#') {
      break;
    }
    token.push_back(static_cast<char>(in.get()));
  }
  return !token.empty();
}

bool load_ppm_rgba8(std::string_view path, int& width_out, int& height_out, std::vector<std::uint8_t>& pixels_out) {
  std::ifstream in(std::string(path), std::ios::binary);
  if (!in) {
    return false;
  }

  std::string magic;
  std::string token;
  if (!read_ppm_token(in, magic) || (magic != "P3" && magic != "P6")) {
    return false;
  }
  if (!read_ppm_token(in, token)) {
    return false;
  }
  width_out = std::stoi(token);
  if (!read_ppm_token(in, token)) {
    return false;
  }
  height_out = std::stoi(token);
  if (!read_ppm_token(in, token)) {
    return false;
  }
  const int max_value = std::stoi(token);
  if (width_out <= 0 || height_out <= 0 || max_value <= 0) {
    return false;
  }

  const size_t pixel_count = static_cast<size_t>(width_out) * static_cast<size_t>(height_out);
  pixels_out.assign(pixel_count * 4, 255);

  auto scale = [max_value](int v) -> std::uint8_t {
    const float normalized = static_cast<float>(v) / static_cast<float>(max_value);
    return static_cast<std::uint8_t>(std::clamp(normalized, 0.0f, 1.0f) * 255.0f);
  };

  if (magic == "P3") {
    for (size_t i = 0; i < pixel_count; ++i) {
      std::string r;
      std::string g;
      std::string b;
      if (!read_ppm_token(in, r) || !read_ppm_token(in, g) || !read_ppm_token(in, b)) {
        return false;
      }
      pixels_out[i * 4 + 0] = scale(std::stoi(r));
      pixels_out[i * 4 + 1] = scale(std::stoi(g));
      pixels_out[i * 4 + 2] = scale(std::stoi(b));
    }
    return true;
  }

  in >> std::ws;
  std::vector<unsigned char> rgb(pixel_count * 3);
  in.read(reinterpret_cast<char*>(rgb.data()), static_cast<std::streamsize>(rgb.size()));
  if (in.gcount() != static_cast<std::streamsize>(rgb.size())) {
    return false;
  }
  for (size_t i = 0; i < pixel_count; ++i) {
    pixels_out[i * 4 + 0] = scale(rgb[i * 3 + 0]);
    pixels_out[i * 4 + 1] = scale(rgb[i * 3 + 1]);
    pixels_out[i * 4 + 2] = scale(rgb[i * 3 + 2]);
  }
  return true;
}

TextureLoadResult make_texture_error(std::string message) {
  TextureLoadResult result;
  result.error_message = std::move(message);
  return result;
}

MTLPixelFormat pixel_format_for_options(const TextureLoadOptions& options) {
  return options.srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
}
 
}  // namespace

struct Backend {
  AppConfig config;
  AppHandler* handler = nullptr;
  InputState input {};
  Renderer public_renderer {this};
  Mat4 view = Mat4::identity();
  Mat4 projection = Mat4::identity();
  Color clear_color {};

  id<MTLDevice> device = nil;
  id<MTLCommandQueue> command_queue = nil;
  id<MTLLibrary> library = nil;
  id<MTLRenderPipelineState> pipeline = nil;
  id<MTLDepthStencilState> depth_state = nil;

  NSApplication* app = nil;
  InputWindow* window = nil;
  MTKView* view_widget = nil;
  LlmMetalViewDelegate* delegate = nil;

  id<MTLCommandBuffer> current_command_buffer = nil;
  id<MTLRenderCommandEncoder> current_encoder = nil;
  MTLRenderPassDescriptor* current_pass = nil;
  bool started = false;
  uint32_t next_texture_id = 1;
  std::uint64_t text_cache_clock = 0;
  std::unordered_map<uint32_t, id<MTLTexture>> textures;
  std::unordered_map<std::string, CachedTextTexture> text_cache;

  void initialize();
  void begin_frame(MTKView* view);
  void end_frame(MTKView* view);
  void update_gamepad_state();
  id<MTLTexture> lookup_texture(TextureHandle handle) const;
  TextureHandle add_texture(id<MTLTexture> texture);
  TextureHandle create_texture_from_pixels(int width, int height, const std::uint8_t* pixels, const TextureLoadOptions& options);
  TextureHandle create_texture_from_cgimage(CGImageRef image, const TextureLoadOptions& options);
  void evict_oldest_text_cache_entry();
  TextureLoadResult load_texture_from_file(std::string_view path, const TextureLoadOptions& options);
  TextureHandle make_text_texture(std::string_view text, float font_size, Color color, Vec2& size_out);
  void issue_draw(std::span<const GpuVertex> vertices, MTLPrimitiveType primitive, const Mat4& mvp, Color modulate, TextureHandle texture, bool enable_depth);
};

namespace {
}  // namespace
}  // namespace llmmetal

@implementation InputWindow
- (BOOL)canBecomeKeyWindow {
  return YES;
}

- (void)keyDown:(NSEvent*)event {
  llmmetal::Backend* backend = self.backendPtr;
  const llmmetal::Key key = llmmetal_map_key_code(event.keyCode);
  const size_t index = llmmetal_key_index(key);
  if (index < std::size(backend->input.keys)) {
    backend->input.keys[index] = true;
    backend->input.pressed[index] = true;
  }
}

- (void)keyUp:(NSEvent*)event {
  llmmetal::Backend* backend = self.backendPtr;
  const llmmetal::Key key = llmmetal_map_key_code(event.keyCode);
  const size_t index = llmmetal_key_index(key);
  if (index < std::size(backend->input.keys)) {
    backend->input.keys[index] = false;
  }
}
@end

@implementation LlmMetalViewDelegate {
  llmmetal::Backend* _backend;
  CFTimeInterval _lastTimestamp;
}

- (instancetype)initWithBackend:(llmmetal::Backend*)backend {
  self = [super init];
  if (self != nil) {
    _backend = backend;
    _lastTimestamp = CACurrentMediaTime();
  }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;
  [_backend->window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  (void)sender;
  return YES;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
  (void)view;
  _backend->projection = llmmetal::Mat4::perspective(60.0f * 3.14159265358979323846f / 180.0f,
                                                     static_cast<float>(size.width / std::max(size.height, 1.0)),
                                                     0.01f,
                                                     100.0f);
}

- (void)drawInMTKView:(MTKView*)view {
  const CFTimeInterval now = CACurrentMediaTime();
  const double dt = now - _lastTimestamp;
  _lastTimestamp = now;

  const NSPoint mouse = [_backend->window mouseLocationOutsideOfEventStream];
  const CGFloat height = _backend->view_widget.bounds.size.height;
  _backend->input.mouse_position = {static_cast<float>(mouse.x), static_cast<float>(height - mouse.y)};
  _backend->update_gamepad_state();

  if (!_backend->started) {
    _backend->started = true;
    _backend->handler->on_start(_backend->public_renderer);
  }

  _backend->begin_frame(view);
  _backend->handler->on_frame(_backend->public_renderer, _backend->input, dt);
  _backend->end_frame(view);
  std::fill(std::begin(_backend->input.pressed), std::end(_backend->input.pressed), false);
}
@end

namespace llmmetal {

void Backend::initialize() {
  app = [NSApplication sharedApplication];
  [app setActivationPolicy:NSApplicationActivationPolicyRegular];

  device = MTLCreateSystemDefaultDevice();
  command_queue = [device newCommandQueue];

  NSError* error = nil;
  library = [device newLibraryWithSource:@(kShaderSource) options:nil error:&error];
  if (library == nil) {
    NSLog(@"Failed to compile Metal shader: %@", error);
    std::abort();
  }

  MTLVertexDescriptor* vertex_desc = [[MTLVertexDescriptor alloc] init];
  vertex_desc.attributes[0].format = MTLVertexFormatFloat3;
  vertex_desc.attributes[0].offset = offsetof(GpuVertex, px);
  vertex_desc.attributes[0].bufferIndex = 0;
  vertex_desc.attributes[1].format = MTLVertexFormatFloat4;
  vertex_desc.attributes[1].offset = offsetof(GpuVertex, cr);
  vertex_desc.attributes[1].bufferIndex = 0;
  vertex_desc.attributes[2].format = MTLVertexFormatFloat2;
  vertex_desc.attributes[2].offset = offsetof(GpuVertex, u);
  vertex_desc.attributes[2].bufferIndex = 0;
  vertex_desc.layouts[0].stride = sizeof(GpuVertex);
  vertex_desc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  id<MTLFunction> vertex_fn = [library newFunctionWithName:@"vertex_main"];
  id<MTLFunction> fragment_fn = [library newFunctionWithName:@"fragment_main"];

  MTLRenderPipelineDescriptor* pipeline_desc = [[MTLRenderPipelineDescriptor alloc] init];
  pipeline_desc.vertexFunction = vertex_fn;
  pipeline_desc.fragmentFunction = fragment_fn;
  pipeline_desc.vertexDescriptor = vertex_desc;
  pipeline_desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  pipeline_desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

  pipeline = [device newRenderPipelineStateWithDescriptor:pipeline_desc error:&error];
  if (pipeline == nil) {
    NSLog(@"Failed to create Metal pipeline: %@", error);
    std::abort();
  }

  MTLDepthStencilDescriptor* depth_desc = [[MTLDepthStencilDescriptor alloc] init];
  depth_desc.depthCompareFunction = MTLCompareFunctionLess;
  depth_desc.depthWriteEnabled = YES;
  depth_state = [device newDepthStencilStateWithDescriptor:depth_desc];

  const NSRect frame = NSMakeRect(100.0, 100.0, static_cast<CGFloat>(config.width), static_cast<CGFloat>(config.height));
  window = [[InputWindow alloc] initWithContentRect:frame
                                          styleMask:(NSWindowStyleMaskTitled |
                                                     NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskResizable |
                                                     NSWindowStyleMaskMiniaturizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
  window.title = [NSString stringWithUTF8String:config.title.c_str()];
  window.backendPtr = this;
  [window makeFirstResponder:window];

  view_widget = [[MTKView alloc] initWithFrame:frame device:device];
  view_widget.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  view_widget.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
  view_widget.preferredFramesPerSecond = 60;
  view_widget.clearColor = MTLClearColorMake(config.clear_color.r, config.clear_color.g, config.clear_color.b, config.clear_color.a);
  view_widget.enableSetNeedsDisplay = NO;
  view_widget.paused = NO;

  delegate = [[LlmMetalViewDelegate alloc] initWithBackend:this];
  view_widget.delegate = delegate;
  app.delegate = delegate;
  window.contentView = view_widget;

  clear_color = config.clear_color;
  projection = Mat4::perspective(60.0f * kPi / 180.0f,
                                 static_cast<float>(config.width) / static_cast<float>(std::max(config.height, 1)),
                                 0.01f,
                                 100.0f);
  view = Mat4::look_at({0.0f, 1.5f, 4.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f});
}

void Backend::begin_frame(MTKView* view_in) {
  view_in.clearColor = MTLClearColorMake(clear_color.r, clear_color.g, clear_color.b, clear_color.a);
  current_pass = view_in.currentRenderPassDescriptor;
  if (current_pass == nil) {
    return;
  }

  current_pass.colorAttachments[0].clearColor = MTLClearColorMake(clear_color.r, clear_color.g, clear_color.b, clear_color.a);
  current_command_buffer = [command_queue commandBuffer];
  current_encoder = [current_command_buffer renderCommandEncoderWithDescriptor:current_pass];
  [current_encoder setRenderPipelineState:pipeline];
  [current_encoder setDepthStencilState:depth_state];
  [current_encoder setCullMode:MTLCullModeNone];
}

void Backend::end_frame(MTKView* view_in) {
  if (current_encoder == nil || current_command_buffer == nil) {
    return;
  }
  [current_encoder endEncoding];
  id<CAMetalDrawable> drawable = view_in.currentDrawable;
  if (drawable != nil) {
    [current_command_buffer presentDrawable:drawable];
  }
  [current_command_buffer commit];
  current_encoder = nil;
  current_command_buffer = nil;
  current_pass = nil;
}

void Backend::update_gamepad_state() {
  input.gamepad = {};
  GCController* controller = GCController.controllers.firstObject;
  if (controller == nil) {
    return;
  }

  GCExtendedGamepad* pad = controller.extendedGamepad;
  if (pad == nil) {
    return;
  }

  input.gamepad.connected = true;
  input.gamepad.left_stick_x = pad.leftThumbstick.xAxis.value;
  input.gamepad.left_stick_y = pad.leftThumbstick.yAxis.value;
  input.gamepad.right_stick_x = pad.rightThumbstick.xAxis.value;
  input.gamepad.right_stick_y = pad.rightThumbstick.yAxis.value;
  input.gamepad.left_trigger = pad.leftTrigger.value;
  input.gamepad.right_trigger = pad.rightTrigger.value;
  input.gamepad.button_a = pad.buttonA.isPressed;
  input.gamepad.button_b = pad.buttonB.isPressed;
  input.gamepad.button_x = pad.buttonX.isPressed;
  input.gamepad.button_y = pad.buttonY.isPressed;
}

id<MTLTexture> Backend::lookup_texture(TextureHandle handle) const {
  const auto it = textures.find(handle.value);
  if (it == textures.end()) {
    return nil;
  }
  return it->second;
}

TextureHandle Backend::add_texture(id<MTLTexture> texture) {
  const uint32_t id = next_texture_id++;
  textures.emplace(id, texture);
  return make_handle(id);
}

TextureHandle Backend::create_texture_from_pixels(int width, int height, const std::uint8_t* pixels, const TextureLoadOptions& options) {
  if (width <= 0 || height <= 0 || pixels == nullptr) {
    return {};
  }

  MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format_for_options(options)
                                                                                  width:static_cast<NSUInteger>(width)
                                                                                 height:static_cast<NSUInteger>(height)
                                                                              mipmapped:options.generate_mipmaps];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  if (texture == nil) {
    return {};
  }

  const MTLRegion region = MTLRegionMake2D(0, 0, width, height);
  [texture replaceRegion:region mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];

  if (options.generate_mipmaps) {
    id<MTLCommandBuffer> command_buffer = [command_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
    [blit generateMipmapsForTexture:texture];
    [blit endEncoding];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
  }

  return add_texture(texture);
}

void Backend::evict_oldest_text_cache_entry() {
  if (text_cache.size() < kMaxTextCacheEntries) {
    return;
  }

  auto oldest = text_cache.end();
  std::uint64_t oldest_tick = std::numeric_limits<std::uint64_t>::max();
  for (auto it = text_cache.begin(); it != text_cache.end(); ++it) {
    if (it->second.last_used < oldest_tick) {
      oldest_tick = it->second.last_used;
      oldest = it;
    }
  }

  if (oldest != text_cache.end()) {
    textures.erase(oldest->second.handle.value);
    text_cache.erase(oldest);
  }
}

TextureHandle Backend::create_texture_from_cgimage(CGImageRef image, const TextureLoadOptions& options) {
  if (image == nil) {
    return {};
  }

  const size_t width = CGImageGetWidth(image);
  const size_t height = CGImageGetHeight(image);
  if (width == 0 || height == 0) {
    return {};
  }

  std::vector<std::uint8_t> pixels(width * height * 4, 0);
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  const uint32_t bitmap_info = static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
                               static_cast<uint32_t>(kCGBitmapByteOrder32Big);
  CGContextRef ctx = CGBitmapContextCreate(pixels.data(),
                                           width,
                                           height,
                                           8,
                                           width * 4,
                                           color_space,
                                           static_cast<CGBitmapInfo>(bitmap_info));
  if (ctx == nullptr) {
    CGColorSpaceRelease(color_space);
    return {};
  }

  if (options.flip_y) {
    CGContextTranslateCTM(ctx, 0.0, static_cast<CGFloat>(height));
    CGContextScaleCTM(ctx, 1.0, -1.0);
  }
  CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, static_cast<CGFloat>(width), static_cast<CGFloat>(height)), image);

  CGContextRelease(ctx);
  CGColorSpaceRelease(color_space);
  return create_texture_from_pixels(static_cast<int>(width), static_cast<int>(height), pixels.data(), options);
}

TextureLoadResult Backend::load_texture_from_file(std::string_view path, const TextureLoadOptions& options) {
  if (path.empty()) {
    return make_texture_error("texture path is empty");
  }

  int ppm_width = 0;
  int ppm_height = 0;
  std::vector<std::uint8_t> ppm_pixels;
  if (load_ppm_rgba8(path, ppm_width, ppm_height, ppm_pixels)) {
    TextureHandle texture = create_texture_from_pixels(ppm_width, ppm_height, ppm_pixels.data(), options);
    if (!texture) {
      return make_texture_error("failed to upload ppm texture to a Metal texture: " + std::string(path));
    }
    return TextureLoadResult {.texture = texture, .error_message = {}};
  }

  NSString* ns_path = [[NSString alloc] initWithBytes:path.data()
                                               length:path.size()
                                             encoding:NSUTF8StringEncoding];
  if (ns_path == nil) {
    return make_texture_error("texture path is not valid UTF-8");
  }

  NSURL* url = [NSURL fileURLWithPath:ns_path];
  if (![[NSFileManager defaultManager] fileExistsAtPath:ns_path]) {
    return make_texture_error("texture file does not exist: " + std::string(path));
  }

  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  if (source == nullptr) {
    return make_texture_error("failed to create image source for: " + std::string(path));
  }

  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  if (image == nullptr) {
    CFRelease(source);
    return make_texture_error("failed to decode image file: " + std::string(path));
  }

  TextureHandle handle = create_texture_from_cgimage(image, options);
  if (image != nullptr) {
    CGImageRelease(image);
  }
  CFRelease(source);
  if (!handle) {
    return make_texture_error("failed to upload decoded image to a Metal texture: " + std::string(path));
  }
  return TextureLoadResult {.texture = handle, .error_message = {}};
}

TextureHandle Backend::make_text_texture(std::string_view text, float font_size, Color color, Vec2& size_out) {
  if (text.empty()) {
    size_out = {};
    return {};
  }

  const std::string cache_key = make_text_cache_key(text, font_size, color);
  if (const auto it = text_cache.find(cache_key); it != text_cache.end()) {
    it->second.last_used = ++text_cache_clock;
    size_out = it->second.size;
    return it->second.handle;
  }

  NSString* ns_text = [[NSString alloc] initWithBytes:text.data()
                                               length:text.size()
                                             encoding:NSUTF8StringEncoding];
  CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, font_size, nullptr);
  NSDictionary* attrs = @{
    (__bridge id)kCTFontAttributeName : (__bridge id)font,
    (__bridge id)kCTForegroundColorAttributeName : (__bridge id)[NSColor colorWithSRGBRed:color.r green:color.g blue:color.b alpha:color.a].CGColor
  };
  NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:ns_text attributes:attrs];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
  const CGRect bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
  const size_t width = std::max<size_t>(1, static_cast<size_t>(std::ceil(bounds.size.width + 4.0)));
  const size_t height = std::max<size_t>(1, static_cast<size_t>(std::ceil(font_size * 1.6f)));
  size_out = {static_cast<float>(width), static_cast<float>(height)};

  std::vector<std::uint8_t> pixels(width * height * 4, 0);
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  const uint32_t bitmap_info = static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
                               static_cast<uint32_t>(kCGBitmapByteOrder32Big);
  CGContextRef ctx = CGBitmapContextCreate(pixels.data(),
                                           width,
                                           height,
                                           8,
                                           width * 4,
                                           color_space,
                                           static_cast<CGBitmapInfo>(bitmap_info));

  CGContextTranslateCTM(ctx, 0.0, static_cast<CGFloat>(height));
  CGContextScaleCTM(ctx, 1.0, -1.0);
  CGContextSetTextPosition(ctx, 2.0, font_size * 0.25f);
  CTLineDraw(line, ctx);

  MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:width
                                                                                 height:height
                                                                              mipmapped:NO];
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  const MTLRegion region = MTLRegionMake2D(0, 0, width, height);
  [texture replaceRegion:region mipmapLevel:0 withBytes:pixels.data() bytesPerRow:width * 4];

  CGContextRelease(ctx);
  CGColorSpaceRelease(color_space);
  CFRelease(line);
  CFRelease(font);
  evict_oldest_text_cache_entry();
  const TextureHandle handle = add_texture(texture);
  text_cache.emplace(cache_key, CachedTextTexture {.handle = handle, .size = size_out, .last_used = ++text_cache_clock});
  return handle;
}

void Backend::issue_draw(std::span<const GpuVertex> vertices,
                         MTLPrimitiveType primitive,
                         const Mat4& mvp,
                         Color modulate,
                         TextureHandle texture,
                         bool enable_depth) {
  if (current_encoder == nil || vertices.empty()) {
    return;
  }

  id<MTLBuffer> vertex_buffer = [device newBufferWithBytes:vertices.data()
                                                    length:vertices.size_bytes()
                                                   options:MTLResourceStorageModeShared];
  Uniforms uniforms {};
  const auto matrix = to_column_major(mvp);
  std::copy(matrix.begin(), matrix.end(), uniforms.mvp);
  uniforms.color[0] = modulate.r;
  uniforms.color[1] = modulate.g;
  uniforms.color[2] = modulate.b;
  uniforms.color[3] = modulate.a;
  uniforms.use_texture = texture ? 1u : 0u;

  id<MTLBuffer> uniform_buffer = [device newBufferWithBytes:&uniforms length:sizeof(uniforms) options:MTLResourceStorageModeShared];
  [current_encoder setDepthStencilState:enable_depth ? depth_state : nil];
  [current_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
  [current_encoder setVertexBuffer:uniform_buffer offset:0 atIndex:1];
  [current_encoder setFragmentBuffer:uniform_buffer offset:0 atIndex:1];
  [current_encoder setFragmentTexture:lookup_texture(texture) atIndex:0];
  [current_encoder drawPrimitives:primitive vertexStart:0 vertexCount:vertices.size()];
}

Mat4 Mat4::identity() {
  Mat4 out {};
  mat_at(out, 0, 0) = 1.0f;
  mat_at(out, 1, 1) = 1.0f;
  mat_at(out, 2, 2) = 1.0f;
  mat_at(out, 3, 3) = 1.0f;
  return out;
}

Mat4 Mat4::orthographic(float left, float right, float bottom, float top, float near_z, float far_z) {
  Mat4 out = identity();
  mat_at(out, 0, 0) = 2.0f / (right - left);
  mat_at(out, 1, 1) = 2.0f / (top - bottom);
  mat_at(out, 2, 2) = 1.0f / (far_z - near_z);
  mat_at(out, 3, 0) = (left + right) / (left - right);
  mat_at(out, 3, 1) = (top + bottom) / (bottom - top);
  mat_at(out, 3, 2) = near_z / (near_z - far_z);
  return out;
}

Mat4 Mat4::perspective(float fov_y_radians, float aspect, float near_z, float far_z) {
  Mat4 out {};
  const float ys = 1.0f / std::tan(fov_y_radians * 0.5f);
  const float xs = ys / aspect;
  mat_at(out, 0, 0) = xs;
  mat_at(out, 1, 1) = ys;
  mat_at(out, 2, 2) = far_z / (far_z - near_z);
  mat_at(out, 2, 3) = 1.0f;
  mat_at(out, 3, 2) = (-near_z * far_z) / (far_z - near_z);
  return out;
}

Mat4 Mat4::translation(Vec3 t) {
  Mat4 out = identity();
  mat_at(out, 3, 0) = t.x;
  mat_at(out, 3, 1) = t.y;
  mat_at(out, 3, 2) = t.z;
  return out;
}

Mat4 Mat4::rotation_y(float radians) {
  Mat4 out = identity();
  const float c = std::cos(radians);
  const float s = std::sin(radians);
  mat_at(out, 0, 0) = c;
  mat_at(out, 0, 2) = -s;
  mat_at(out, 2, 0) = s;
  mat_at(out, 2, 2) = c;
  return out;
}

Mat4 Mat4::look_at(Vec3 eye, Vec3 target, Vec3 up) {
  const Vec3 z = normalize(target - eye);
  const Vec3 x = normalize(cross(up, z));
  const Vec3 y = cross(z, x);

  Mat4 out = identity();
  mat_at(out, 0, 0) = x.x;
  mat_at(out, 0, 1) = x.y;
  mat_at(out, 0, 2) = x.z;
  mat_at(out, 1, 0) = y.x;
  mat_at(out, 1, 1) = y.y;
  mat_at(out, 1, 2) = y.z;
  mat_at(out, 2, 0) = z.x;
  mat_at(out, 2, 1) = z.y;
  mat_at(out, 2, 2) = z.z;
  mat_at(out, 3, 0) = -dot(x, eye);
  mat_at(out, 3, 1) = -dot(y, eye);
  mat_at(out, 3, 2) = -dot(z, eye);
  return out;
}

Mat4 operator*(const Mat4& a, const Mat4& b) {
  Mat4 out {};
  for (int col = 0; col < 4; ++col) {
    for (int row = 0; row < 4; ++row) {
      mat_at(out, col, row) =
          mat_at(a, 0, row) * mat_at(b, col, 0) +
          mat_at(a, 1, row) * mat_at(b, col, 1) +
          mat_at(a, 2, row) * mat_at(b, col, 2) +
          mat_at(a, 3, row) * mat_at(b, col, 3);
    }
  }
  return out;
}

bool InputState::is_key_down(Key key) const {
  const size_t index = llmmetal_key_index(key);
  return index < std::size(keys) ? keys[index] : false;
}

bool InputState::was_key_pressed(Key key) const {
  const size_t index = llmmetal_key_index(key);
  return index < std::size(pressed) ? pressed[index] : false;
}

Renderer::Renderer(Renderer&& other) noexcept : impl_(std::exchange(other.impl_, nullptr)) {}

Renderer& Renderer::operator=(Renderer&& other) noexcept {
  if (this != &other) {
    impl_ = std::exchange(other.impl_, nullptr);
  }
  return *this;
}

Renderer::~Renderer() = default;

void Renderer::clear(Color color) {
  auto* backend = static_cast<Backend*>(impl_);
  backend->clear_color = color;
  if (backend->view_widget != nil) {
    backend->view_widget.clearColor = MTLClearColorMake(color.r, color.g, color.b, color.a);
  }
  if (backend->current_pass != nil) {
    backend->current_pass.colorAttachments[0].clearColor = MTLClearColorMake(color.r, color.g, color.b, color.a);
  }
}

void Renderer::set_camera(const Mat4& view, const Mat4& projection) {
  auto* backend = static_cast<Backend*>(impl_);
  backend->view = view;
  backend->projection = projection;
}

TextureHandle Renderer::create_texture_rgba8(int width, int height, const std::uint8_t* rgba8_pixels) {
  auto* backend = static_cast<Backend*>(impl_);
  return backend->create_texture_from_pixels(width, height, rgba8_pixels, {});
}

TextureHandle Renderer::create_texture_from_file(const std::filesystem::path& path, const TextureLoadOptions& options) {
  const std::string utf8_path = path_to_utf8(path);
  return try_create_texture_from_file(std::string_view(utf8_path), options).texture;
}

TextureHandle Renderer::create_texture_from_file(std::string_view path, const TextureLoadOptions& options) {
  auto* backend = static_cast<Backend*>(impl_);
  return backend->load_texture_from_file(path, options).texture;
}

TextureHandle Renderer::create_texture_from_file(const std::filesystem::path& path) {
  const std::string utf8_path = path_to_utf8(path);
  return try_create_texture_from_file(std::string_view(utf8_path), {}).texture;
}

TextureHandle Renderer::create_texture_from_file(std::string_view path) {
  return create_texture_from_file(path, {});
}

TextureLoadResult Renderer::try_create_texture_from_file(const std::filesystem::path& path, const TextureLoadOptions& options) {
  const std::string utf8_path = path_to_utf8(path);
  return try_create_texture_from_file(std::string_view(utf8_path), options);
}

TextureLoadResult Renderer::try_create_texture_from_file(std::string_view path, const TextureLoadOptions& options) {
  auto* backend = static_cast<Backend*>(impl_);
  return backend->load_texture_from_file(path, options);
}

TextureLoadResult Renderer::try_create_texture_from_file(const std::filesystem::path& path) {
  const std::string utf8_path = path_to_utf8(path);
  return try_create_texture_from_file(std::string_view(utf8_path), {});
}

TextureLoadResult Renderer::try_create_texture_from_file(std::string_view path) {
  return try_create_texture_from_file(path, {});
}

TextureHandle Renderer::create_checkerboard_texture(int width, int height, int cell_size) {
  std::vector<std::uint8_t> pixels(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const bool dark = ((x / cell_size) + (y / cell_size)) % 2 == 0;
      const std::uint8_t value = dark ? 50 : 220;
      const size_t offset = static_cast<size_t>(y * width + x) * 4;
      pixels[offset + 0] = value;
      pixels[offset + 1] = dark ? 120 : 80;
      pixels[offset + 2] = dark ? 240 : 40;
      pixels[offset + 3] = 255;
    }
  }
  return create_texture_rgba8(width, height, pixels.data());
}

void Renderer::destroy_texture(TextureHandle texture) {
  auto* backend = static_cast<Backend*>(impl_);
  backend->textures.erase(texture.value);
  for (auto it = backend->text_cache.begin(); it != backend->text_cache.end();) {
    if (it->second.handle.value == texture.value) {
      it = backend->text_cache.erase(it);
    } else {
      ++it;
    }
  }
}

void Renderer::draw_line_2d(Vec2 a, Vec2 b, Color color, float thickness) {
  auto* backend = static_cast<Backend*>(impl_);
  const Vec2 dir {b.x - a.x, b.y - a.y};
  const float len = std::sqrt(dir.x * dir.x + dir.y * dir.y);
  if (len <= 0.0f) {
    return;
  }
  const Vec2 n {-dir.y / len, dir.x / len};
  const Vec2 half {n.x * thickness * 0.5f, n.y * thickness * 0.5f};

  const Vec3 p0 {a.x - half.x, a.y - half.y, 0.0f};
  const Vec3 p1 {a.x + half.x, a.y + half.y, 0.0f};
  const Vec3 p2 {b.x + half.x, b.y + half.y, 0.0f};
  const Vec3 p3 {b.x - half.x, b.y - half.y, 0.0f};
  const std::array<GpuVertex, 6> vertices {
    make_vertex(p0, color), make_vertex(p1, color), make_vertex(p2, color),
    make_vertex(p0, color), make_vertex(p2, color), make_vertex(p3, color)
  };
  const Mat4 ortho = Mat4::orthographic(0.0f,
                                        static_cast<float>(drawable_width()),
                                        static_cast<float>(drawable_height()),
                                        0.0f,
                                        -1.0f,
                                        1.0f);
  backend->issue_draw(vertices, MTLPrimitiveTypeTriangle, ortho, {1, 1, 1, 1}, {}, false);
}

void Renderer::draw_line_3d(Vec3 a, Vec3 b, Color color) {
  auto* backend = static_cast<Backend*>(impl_);
  const std::array<GpuVertex, 2> vertices {make_vertex(a, color), make_vertex(b, color)};
  backend->issue_draw(vertices, MTLPrimitiveTypeLine, backend->projection * backend->view, {1, 1, 1, 1}, {}, true);
}

void Renderer::draw_triangle_3d(const Vertex3D& a, const Vertex3D& b, const Vertex3D& c, TextureHandle texture) {
  auto* backend = static_cast<Backend*>(impl_);
  const std::array<GpuVertex, 3> vertices {
    make_vertex(a.position, a.color, a.uv),
    make_vertex(b.position, b.color, b.uv),
    make_vertex(c.position, c.color, c.uv),
  };
  backend->issue_draw(vertices, MTLPrimitiveTypeTriangle, backend->projection * backend->view, {1, 1, 1, 1}, texture, true);
}

void Renderer::draw_plane_3d(Vec3 center, Vec2 size, Color color, TextureHandle texture) {
  auto* backend = static_cast<Backend*>(impl_);
  const float hx = size.x * 0.5f;
  const float hy = size.y * 0.5f;
  const Vec3 p0 {center.x - hx, center.y, center.z - hy};
  const Vec3 p1 {center.x + hx, center.y, center.z - hy};
  const Vec3 p2 {center.x + hx, center.y, center.z + hy};
  const Vec3 p3 {center.x - hx, center.y, center.z + hy};
  const std::array<GpuVertex, 6> vertices {
    make_vertex(p0, color, {0.0f, 1.0f}), make_vertex(p1, color, {1.0f, 1.0f}), make_vertex(p2, color, {1.0f, 0.0f}),
    make_vertex(p0, color, {0.0f, 1.0f}), make_vertex(p2, color, {1.0f, 0.0f}), make_vertex(p3, color, {0.0f, 0.0f}),
  };
  backend->issue_draw(vertices, MTLPrimitiveTypeTriangle, backend->projection * backend->view, {1, 1, 1, 1}, texture, true);
}

void Renderer::draw_text_2d(std::string_view text, Vec2 position_pixels, float font_size_pixels, Color color) {
  auto* backend = static_cast<Backend*>(impl_);
  Vec2 size {};
  const TextureHandle texture = backend->make_text_texture(text, font_size_pixels, color, size);
  if (!texture) {
    return;
  }

  const float x = position_pixels.x;
  const float y = position_pixels.y;
  const Vec3 p0 {x, y, 0.0f};
  const Vec3 p1 {x + size.x, y, 0.0f};
  const Vec3 p2 {x + size.x, y + size.y, 0.0f};
  const Vec3 p3 {x, y + size.y, 0.0f};
  const std::array<GpuVertex, 6> vertices {
    make_vertex(p0, {1, 1, 1, 1}, {0.0f, 1.0f}), make_vertex(p1, {1, 1, 1, 1}, {1.0f, 1.0f}), make_vertex(p2, {1, 1, 1, 1}, {1.0f, 0.0f}),
    make_vertex(p0, {1, 1, 1, 1}, {0.0f, 1.0f}), make_vertex(p2, {1, 1, 1, 1}, {1.0f, 0.0f}), make_vertex(p3, {1, 1, 1, 1}, {0.0f, 0.0f}),
  };
  const Mat4 ortho = Mat4::orthographic(0.0f,
                                        static_cast<float>(drawable_width()),
                                        static_cast<float>(drawable_height()),
                                        0.0f,
                                        -1.0f,
                                        1.0f);
  backend->issue_draw(vertices, MTLPrimitiveTypeTriangle, ortho, {1, 1, 1, 1}, texture, false);
}

int Renderer::drawable_width() const {
  auto* backend = static_cast<Backend*>(impl_);
  return static_cast<int>(backend->view_widget.drawableSize.width);
}

int Renderer::drawable_height() const {
  auto* backend = static_cast<Backend*>(impl_);
  return static_cast<int>(backend->view_widget.drawableSize.height);
}

int run(const AppConfig& config, AppHandler& handler) {
  @autoreleasepool {
    Backend backend;
    backend.config = config;
    backend.handler = &handler;
    backend.initialize();
    [backend.app activateIgnoringOtherApps:YES];
    [backend.app run];
    handler.on_shutdown();
    return 0;
  }
}

}  // namespace llmmetal
