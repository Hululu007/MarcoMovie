# Marco Movie — macOS 桌面端（独立工程）

`macos/` 是 Marco Movie 的**独立 macOS 桌面端（Apple Silicon & Intel Universal）** Flutter 工程目录，与 `flutter/`（iOS / iPadOS / Windows / HarmonyOS）彻底解耦、各自独立演进与发版。

- **版本清单**：`macos/edition-versions.json`
- **CI 构建任务**：`.github/workflows/build-multiplatform.yml` → `build-macos`（`workflow_dispatch` `target=macos`）
- **更新通道**：`updates/macos.json`
- **独立验证命令**：
  - Runner 回归：`python3 -m unittest discover -s macos -p "test_*.py"`
  - 代码分析与测试：`cd macos && flutter pub get && flutter analyze --no-fatal-infos --no-fatal-warnings && flutter test`
  - 成品验包：`python3 scripts/verify_macos_candidate.py --app <MarcoMovie.app> --flutter-dir macos`
