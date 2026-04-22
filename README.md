# llmmetal

macOS 向けの小さな Metal 描画ライブラリです。アプリケーション側は C++20 のみで記述し、内部で Cocoa / Metal / CoreText / GameController を利用します。

## 対応範囲

- 2D/3D の基本プリミティブ描画
- 3D ユーティリティ形状: Cube / Cylinder / Sphere
- RGBA8 テクスチャ生成、画像ファイル読込、貼り付け
- システムフォントを使った 2D 文字列描画
- キーボードと GameController 入力
- CMake + Ninja + Homebrew LLVM

## ビルド

```bash
cmake --preset default
cmake --build --preset default
```

## サンプル

- `sample_lines`: 2D/3D ライン、三角形、Cube / Cylinder / Sphere
- `sample_texture`: ファイル読込テクスチャ付き Plane
- `sample_input_text`: キーボード/GameController 状態と文字列描画

`Renderer::create_texture_from_file()` は `std::filesystem::path` と `std::string_view` の両方を受け付けます。PNG / JPEG など ImageIO で読める形式を利用できます。

失敗理由が必要な場合は `Renderer::try_create_texture_from_file()` を使うと、`TextureLoadResult` で `error_message` を取得できます。

`TextureLoadOptions` で `srgb`, `flip_y`, `generate_mipmaps` を指定できます。

文字列描画は内部で LRU キャッシュされ、同じ内容の再描画では再ラスタライズを避けます。キャッシュは固定上限で古い項目から破棄します。

3D の簡易ライティングは `Renderer::set_light_direction()`, `Renderer::set_ambient_light()`, `Renderer::set_specular_strength()`, `Renderer::set_shininess()` で調整できます。specular を使う場合は `Renderer::set_camera_position()` も設定してください。
