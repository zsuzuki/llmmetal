#include "llmmetal/llmmetal.hpp"

#include <cmath>
#include <filesystem>

using namespace llmmetal;

namespace {

class Demo final : public AppHandler {
public:
  void on_start(Renderer& renderer) override {
    TextureLoadOptions options;
    options.srgb = true;
    options.flip_y = false;
    options.generate_mipmaps = true;
    const TextureLoadResult loaded = renderer.try_create_texture_from_file(std::filesystem::path("resources") / "checker.ppm", options);
    checker_ = loaded.texture;
    load_error_ = loaded.error_message;
    if (!checker_) {
      checker_ = renderer.create_checkerboard_texture(256, 256, 32);
    }
  }

  void on_frame(Renderer& renderer, const InputState&, double dt) override {
    time_ += static_cast<float>(dt);
    renderer.clear({0.05f, 0.06f, 0.08f, 1.0f});

    const float aspect = static_cast<float>(renderer.drawable_width()) / static_cast<float>(renderer.drawable_height());
    renderer.set_camera(Mat4::look_at({std::sin(time_) * 3.5f, 2.0f, std::cos(time_) * 3.5f},
                                      {0.0f, 0.0f, 0.0f},
                                      {0.0f, 1.0f, 0.0f}),
                        Mat4::perspective(55.0f * 3.14159265f / 180.0f, aspect, 0.01f, 100.0f));

    renderer.draw_plane_3d({0.0f, -0.75f, 0.0f}, {3.0f, 3.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, checker_);
    renderer.draw_triangle_3d(
        {{-0.75f, 0.4f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {0.0f, 1.0f}},
        {{0.0f, 1.7f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {0.5f, 0.0f}},
        {{0.75f, 0.4f, 0.0f}, {1.0f, 1.0f, 1.0f, 1.0f}, {1.0f, 1.0f}},
        checker_);

    renderer.draw_text_2d("textured triangle + plane (file texture + options)", {30.0f, 26.0f}, 24.0f, {0.94f, 0.96f, 1.0f, 1.0f});
    if (!load_error_.empty()) {
      renderer.draw_text_2d(load_error_, {30.0f, 58.0f}, 16.0f, {1.0f, 0.75f, 0.68f, 1.0f});
    }
  }

private:
  TextureHandle checker_ {};
  float time_ = 0.0f;
  std::string load_error_;
};

}  // namespace

int main() {
  Demo demo;
  AppConfig config;
  config.title = "llmmetal - sample_texture";
  return run(config, demo);
}
