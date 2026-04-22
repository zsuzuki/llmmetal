#include "llmmetal/llmmetal.hpp"

#include <cstdio>
#include <string>

using namespace llmmetal;

namespace {

class Demo final : public AppHandler {
public:
  void on_frame(Renderer& renderer, const InputState& input, double) override {
    renderer.clear({0.12f, 0.12f, 0.10f, 1.0f});

    std::string line1 = input.gamepad.connected ? "Gamepad: connected" : "Gamepad: not connected";
    std::string line2 = "Move camera hint: WASD / Arrow keys";
    std::string line3 = "Pressed:";
    if (input.is_key_down(Key::w)) { line3 += " W"; }
    if (input.is_key_down(Key::a)) { line3 += " A"; }
    if (input.is_key_down(Key::s)) { line3 += " S"; }
    if (input.is_key_down(Key::d)) { line3 += " D"; }
    if (input.is_key_down(Key::left)) { line3 += " Left"; }
    if (input.is_key_down(Key::right)) { line3 += " Right"; }
    if (input.is_key_down(Key::up)) { line3 += " Up"; }
    if (input.is_key_down(Key::down)) { line3 += " Down"; }

    char stick_line[128];
    std::snprintf(stick_line,
                  sizeof(stick_line),
                  "LeftStick %.2f %.2f  RightStick %.2f %.2f",
                  input.gamepad.left_stick_x,
                  input.gamepad.left_stick_y,
                  input.gamepad.right_stick_x,
                  input.gamepad.right_stick_y);

    renderer.draw_text_2d("sample_input_text", {30.0f, 24.0f}, 28.0f, {0.97f, 0.97f, 0.92f, 1.0f});
    renderer.draw_text_2d(line1, {30.0f, 70.0f}, 22.0f, {0.80f, 0.95f, 1.0f, 1.0f});
    renderer.draw_text_2d(line2, {30.0f, 100.0f}, 20.0f, {0.90f, 0.90f, 0.82f, 1.0f});
    renderer.draw_text_2d(line3, {30.0f, 132.0f}, 20.0f, {0.96f, 0.82f, 0.70f, 1.0f});
    renderer.draw_text_2d(stick_line, {30.0f, 162.0f}, 20.0f, {0.75f, 0.88f, 0.74f, 1.0f});

    const Vec2 center {420.0f + input.gamepad.left_stick_x * 100.0f, 290.0f - input.gamepad.left_stick_y * 100.0f};
    renderer.draw_line_2d({320.0f, 290.0f}, {520.0f, 290.0f}, {0.45f, 0.45f, 0.45f, 1.0f}, 2.0f);
    renderer.draw_line_2d({420.0f, 190.0f}, {420.0f, 390.0f}, {0.45f, 0.45f, 0.45f, 1.0f}, 2.0f);
    renderer.draw_line_2d({420.0f, 290.0f}, center, {0.95f, 0.50f, 0.35f, 1.0f}, 6.0f);
  }
};

}  // namespace

int main() {
  Demo demo;
  AppConfig config;
  config.title = "llmmetal - sample_input_text";
  return run(config, demo);
}
