#include "llmmetal/llmmetal.hpp"

#include <cmath>

using namespace llmmetal;

namespace {

class Demo final : public AppHandler {
public:
  void on_frame(Renderer &renderer, const InputState &, double dt) override {
    angle_ += static_cast<float>(dt) * 0.8f;
    renderer.clear({0.09f, 0.10f, 0.14f, 1.0f});

    const float aspect = static_cast<float>(renderer.drawable_width()) /
                         static_cast<float>(renderer.drawable_height());
    const Vec3 eye{std::sin(angle_) * 3.0f, 1.8f, std::cos(angle_) * 3.0f};
    renderer.set_camera(
        Mat4::look_at(eye, {0.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}),
        Mat4::perspective(60.0f * 3.14159265f / 180.0f, aspect, 0.01f, 100.0f));
    renderer.set_camera_position(eye);
    renderer.set_light_direction(
        {std::cos(angle_ * 0.7f), -1.0f, std::sin(angle_ * 0.7f) - 0.2f});
    renderer.set_ambient_light(0.28f);
    renderer.set_specular_strength(0.22f);
    renderer.set_shininess(36.0f);

    renderer.draw_line_3d({-1.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f},
                          {1.0f, 0.2f, 0.2f, 1.0f});
    renderer.draw_line_3d({0.0f, -1.0f, 0.0f}, {0.0f, 1.0f, 0.0f},
                          {0.2f, 1.0f, 0.2f, 1.0f});
    renderer.draw_line_3d({0.0f, 0.0f, -1.0f}, {0.0f, 0.0f, 1.0f},
                          {0.2f, 0.6f, 1.0f, 1.0f});

    renderer.draw_triangle_3d(
        {{-0.8f, 0.0f, 0.0f}, {1.0f, 0.3f, 0.1f, 1.0f}, {0.0f, 1.0f}},
        {{0.0f, 1.2f, 0.0f}, {0.2f, 1.0f, 0.5f, 1.0f}, {0.5f, 0.0f}},
        {{0.8f, 0.0f, 0.0f}, {0.1f, 0.5f, 1.0f, 1.0f}, {1.0f, 1.0f}});

    renderer.draw_cube_3d({-1.7f, -0.1f, -0.4f}, {0.6f, 0.6f, 0.6f},
                          {angle_ * 0.7f, angle_ * 1.1f, angle_ * 0.35f},
                          {0.95f, 0.55f, 0.25f, 1.0f});
    renderer.draw_cylinder_3d({0.0f, -0.2f, -0.9f}, 0.35f, 0.9f, 24,
                              {0.0f, angle_ * 0.9f, angle_ * 0.25f},
                              {0.30f, 0.82f, 0.92f, 1.0f});
    renderer.draw_sphere_3d({1.7f, -0.1f, -0.4f}, 0.42f, 24, 16,
                            {0.65f, 0.85f, 0.35f, 1.0f});

    renderer.draw_line_2d({60.0f, 60.0f}, {300.0f, 110.0f},
                          {1.0f, 0.9f, 0.3f, 1.0f}, 8.0f);
    renderer.draw_text_2d("sample_lines + rotated cube/cylinder",
                          {40.0f, 24.0f}, 32.0f, {0.95f, 0.95f, 0.98f, 1.0f});
  }

private:
  float angle_ = 0.0f;
};

} // namespace

int main() {
  Demo demo;
  AppConfig config;
  config.title = "llmmetal - sample_lines";
  return run(config, demo);
}
