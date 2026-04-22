#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

namespace llmmetal {

struct Vec2 {
  float x = 0.0f;
  float y = 0.0f;
};

struct Vec3 {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};

struct Vec4 {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  float w = 0.0f;
};

struct Color {
  float r = 1.0f;
  float g = 1.0f;
  float b = 1.0f;
  float a = 1.0f;
};

struct Mat4 {
  float m[16] {};

  static Mat4 identity();
  static Mat4 orthographic(float left, float right, float bottom, float top, float near_z, float far_z);
  static Mat4 perspective(float fov_y_radians, float aspect, float near_z, float far_z);
  static Mat4 translation(Vec3 t);
  static Mat4 rotation_y(float radians);
  static Mat4 look_at(Vec3 eye, Vec3 target, Vec3 up);
};

Mat4 operator*(const Mat4& a, const Mat4& b);

struct Vertex3D {
  Vec3 position {};
  Color color {};
  Vec2 uv {};
};

struct TextureHandle {
  std::uint32_t value = 0;
  explicit operator bool() const { return value != 0; }
};

struct TextureLoadResult {
  TextureHandle texture {};
  std::string error_message;

  explicit operator bool() const { return static_cast<bool>(texture); }
};

struct TextureLoadOptions {
  bool srgb = false;
  bool flip_y = true;
  bool generate_mipmaps = false;
};

enum class Key : std::uint16_t {
  unknown = 0,
  escape,
  space,
  left,
  right,
  up,
  down,
  a,
  d,
  s,
  w,
  q,
  e,
  r,
  f,
  z,
  x,
  c,
  v
};

struct GamepadState {
  bool connected = false;
  float left_stick_x = 0.0f;
  float left_stick_y = 0.0f;
  float right_stick_x = 0.0f;
  float right_stick_y = 0.0f;
  float left_trigger = 0.0f;
  float right_trigger = 0.0f;
  bool button_a = false;
  bool button_b = false;
  bool button_x = false;
  bool button_y = false;
};

struct InputState {
  bool keys[256] {};
  bool pressed[256] {};
  Vec2 mouse_position {};
  GamepadState gamepad {};

  bool is_key_down(Key key) const;
  bool was_key_pressed(Key key) const;
};

struct AppConfig {
  int width = 1280;
  int height = 720;
  std::string title = "llmmetal";
  Color clear_color {0.08f, 0.09f, 0.11f, 1.0f};
};

class Renderer {
public:
  Renderer() = default;
  explicit Renderer(void* impl) : impl_(impl) {}
  Renderer(const Renderer&) = delete;
  Renderer& operator=(const Renderer&) = delete;
  Renderer(Renderer&&) noexcept;
  Renderer& operator=(Renderer&&) noexcept;
  ~Renderer();

  void clear(Color color);
  void set_camera(const Mat4& view, const Mat4& projection);
  void set_camera_position(Vec3 position);
  void set_light_direction(Vec3 direction);
  void set_ambient_light(float ambient);
  void set_specular_strength(float strength);
  void set_shininess(float shininess);

  TextureHandle create_texture_rgba8(int width, int height, const std::uint8_t* rgba8_pixels);
  TextureLoadResult try_create_texture_from_file(const std::filesystem::path& path, const TextureLoadOptions& options);
  TextureLoadResult try_create_texture_from_file(std::string_view path, const TextureLoadOptions& options);
  TextureLoadResult try_create_texture_from_file(const std::filesystem::path& path);
  TextureLoadResult try_create_texture_from_file(std::string_view path);
  TextureHandle create_texture_from_file(const std::filesystem::path& path, const TextureLoadOptions& options);
  TextureHandle create_texture_from_file(std::string_view path, const TextureLoadOptions& options);
  TextureHandle create_texture_from_file(const std::filesystem::path& path);
  TextureHandle create_texture_from_file(std::string_view path);
  TextureHandle create_checkerboard_texture(int width, int height, int cell_size);
  void destroy_texture(TextureHandle texture);

  void draw_line_2d(Vec2 a, Vec2 b, Color color, float thickness = 1.0f);
  void draw_line_3d(Vec3 a, Vec3 b, Color color);
  void draw_triangle_3d(const Vertex3D& a, const Vertex3D& b, const Vertex3D& c, TextureHandle texture = {});
  void draw_plane_3d(Vec3 center, Vec2 size, Color color, TextureHandle texture = {});
  void draw_cube_3d(Vec3 center, Vec3 size, Vec3 rotation_radians, Color color, TextureHandle texture = {});
  void draw_cube_3d(Vec3 center, Vec3 size, Color color, TextureHandle texture = {});
  void draw_cylinder_3d(Vec3 center, float radius, float height, int segments, Vec3 rotation_radians, Color color, TextureHandle texture = {});
  void draw_cylinder_3d(Vec3 center, float radius, float height, int segments, Color color, TextureHandle texture = {});
  void draw_sphere_3d(Vec3 center, float radius, int slices, int stacks, Color color, TextureHandle texture = {});
  void draw_text_2d(std::string_view text, Vec2 position_pixels, float font_size_pixels, Color color);

  int drawable_width() const;
  int drawable_height() const;

private:
  void* impl_ = nullptr;

  friend int run(const AppConfig&, class AppHandler&);
};

class AppHandler {
public:
  virtual ~AppHandler() = default;
  virtual void on_start(Renderer&) {}
  virtual void on_frame(Renderer&, const InputState&, double dt_seconds) = 0;
  virtual void on_shutdown() {}
};

int run(const AppConfig& config, AppHandler& handler);

}  // namespace llmmetal
