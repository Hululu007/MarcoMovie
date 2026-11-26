"""Verify prepare_platform.py idempotently patches Windows centering & placement persistence."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

import prepare_platform


SAMPLE_MAIN_CPP = """#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  flutter::DartProject project(L"data");
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"marco_movie", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
"""

SAMPLE_W32_H = """#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

class Win32Window {
 protected:
  virtual bool OnCreate();
  virtual void OnDestroy();
 private:
  HWND window_handle_ = nullptr;
  HWND child_content_ = nullptr;
};

#endif
"""

SAMPLE_W32_CPP = """#include "win32_window.h"

LRESULT Win32Window::MessageHandler(HWND hwnd, UINT const message,
                                    WPARAM const wparam,
                                    LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }
    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;
  }
  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}
"""

SAMPLE_FW_H = """#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();
 private:
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif
"""

SAMPLE_FW_CPP = """#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }
  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
"""

SAMPLE_CMAKE = """target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
"""


class PrepareWindowsRunnerTests(unittest.TestCase):
    def test_windows_runner_centering_placement_and_safe_shutdown_patch_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fake_root = Path(tmp) / "flutter"
            win_runner = fake_root / "windows" / "runner"
            (win_runner / "resources").mkdir(parents=True, exist_ok=True)
            (win_runner / "main.cpp").write_text(SAMPLE_MAIN_CPP, encoding="utf-8")
            (win_runner / "win32_window.h").write_text(SAMPLE_W32_H, encoding="utf-8")
            (win_runner / "win32_window.cpp").write_text(SAMPLE_W32_CPP, encoding="utf-8")
            (win_runner / "flutter_window.h").write_text(SAMPLE_FW_H, encoding="utf-8")
            (win_runner / "flutter_window.cpp").write_text(SAMPLE_FW_CPP, encoding="utf-8")
            (win_runner / "CMakeLists.txt").write_text(SAMPLE_CMAKE, encoding="utf-8")

            orig_root = prepare_platform.ROOT
            try:
                prepare_platform.ROOT = fake_root
                self._run_windows_patch(fake_root)
                first_main = (win_runner / "main.cpp").read_text(encoding="utf-8")
                first_w32_h = (win_runner / "win32_window.h").read_text(encoding="utf-8")
                first_w32_cpp = (win_runner / "win32_window.cpp").read_text(encoding="utf-8")
                first_h = (win_runner / "flutter_window.h").read_text(encoding="utf-8")
                first_cpp = (win_runner / "flutter_window.cpp").read_text(encoding="utf-8")
                first_cmake = (win_runner / "CMakeLists.txt").read_text(encoding="utf-8")

                # Second and third passes must be strictly idempotent
                self._run_windows_patch(fake_root)
                self._run_windows_patch(fake_root)
                self.assertEqual(first_main, (win_runner / "main.cpp").read_text(encoding="utf-8"))
                self.assertEqual(first_w32_h, (win_runner / "win32_window.h").read_text(encoding="utf-8"))
                self.assertEqual(first_w32_cpp, (win_runner / "win32_window.cpp").read_text(encoding="utf-8"))
                self.assertEqual(first_h, (win_runner / "flutter_window.h").read_text(encoding="utf-8"))
                self.assertEqual(first_cpp, (win_runner / "flutter_window.cpp").read_text(encoding="utf-8"))
                self.assertEqual(first_cmake, (win_runner / "CMakeLists.txt").read_text(encoding="utf-8"))

                # Centering & placement persistence
                self.assertIn("MONITOR_DEFAULTTOPRIMARY", first_main)
                self.assertIn("FlutterDesktopGetDpiForMonitor", first_main)
                self.assertIn("ApplyInitialWindowPlacement()", first_h)
                self.assertIn("window_bounds_channel_", first_h)
                self.assertIn("ApplyInitialWindowPlacement();", first_cpp)
                self.assertIn("ShowInitialWindow();", first_cpp)
                self.assertIn("marco_movie/windows_window_bounds", first_cpp)
                self.assertIn("case WM_EXITSIZEMOVE:", first_cpp)

                # Safe shutdown before CoUninitialize()
                self.assertIn("window.Destroy();", first_main)
                self.assertLess(
                    first_main.index("window.Destroy();"),
                    first_main.index("::CoUninitialize();"),
                )
                self.assertIn("void ClearChildContent();", first_w32_h)
                self.assertIn("case WM_NCDESTROY:", first_w32_cpp)
                self.assertIn("return DefWindowProc(hwnd, message, wparam, lparam);", first_w32_cpp)
                self.assertNotIn("return DefWindowProc(window_handle_,", first_w32_cpp)
                self.assertIn("HWND hwnd = window_handle_;", first_w32_cpp)

                # Re-entrancy & controller teardown guards
                self.assertIn("bool has_created_content_ = false;", first_h)
                self.assertIn("bool is_shutting_down_ = false;", first_h)
                self.assertIn("bool on_destroy_completed_ = false;", first_h)
                self.assertIn("kExitWindowMsg", first_h)
                self.assertIn("has_created_content_ = true;", first_cpp)
                self.assertIn("if (!has_created_content_ || on_destroy_completed_)", first_cpp)
                self.assertIn("FlutterWindow::~FlutterWindow() {\n  Destroy();\n}", first_cpp)
                self.assertIn('call.method_name() == "destroyWindow"', first_cpp)
                self.assertIn("auto controller = std::move(flutter_controller_);", first_cpp)
                self.assertIn("controller.reset();", first_cpp)
                self.assertIn("ClearChildContent();", first_cpp)
                self.assertIn("if (message == WM_DESTROY)", first_cpp)
                self.assertIn("if (is_shutting_down_)", first_cpp)
                self.assertIn("if (!is_shutting_down_ && flutter_controller_ &&\n          flutter_controller_->engine())", first_cpp)

                # Ensure WM_EXITSIZEMOVE was injected inside MessageHandler, NOT OnDestroy
                destroy_idx = first_cpp.index("void FlutterWindow::OnDestroy()")
                msg_idx = first_cpp.index("FlutterWindow::MessageHandler(")
                hook_idx = first_cpp.index("case WM_EXITSIZEMOVE:")
                self.assertGreater(hook_idx, msg_idx)
                self.assertGreater(msg_idx, destroy_idx)
                self.assertIn("window_bounds_channel_->SetMethodCallHandler(nullptr);", first_cpp)
                self.assertIn("window_bounds_channel_.reset();", first_cpp)
                self.assertIn("kWindowPlacementRegPath", first_cpp)
                self.assertIn('"advapi32.lib"', first_cmake)
                self.assertIn('"shell32.lib"', first_cmake)
            finally:
                prepare_platform.ROOT = orig_root

    def _assert_upgraded_runner_complete_and_idempotent(self, fake_root: Path) -> None:
        win_runner = fake_root / "windows" / "runner"
        orig_root = prepare_platform.ROOT
        try:
            prepare_platform.ROOT = fake_root
            self._run_windows_patch(fake_root)
            upgraded_h = (win_runner / "flutter_window.h").read_text(encoding="utf-8")
            upgraded_cpp = (win_runner / "flutter_window.cpp").read_text(encoding="utf-8")
            upgraded_main = (win_runner / "main.cpp").read_text(encoding="utf-8")

            # Re-running must stay strictly idempotent.
            self._run_windows_patch(fake_root)
            self.assertEqual(upgraded_h, (win_runner / "flutter_window.h").read_text(encoding="utf-8"))
            self.assertEqual(upgraded_cpp, (win_runner / "flutter_window.cpp").read_text(encoding="utf-8"))
            self.assertEqual(upgraded_main, (win_runner / "main.cpp").read_text(encoding="utf-8"))

            self.assertIn('call.method_name() == "destroyWindow"', upgraded_cpp)
            self.assertIn("if (message == kExitWindowMsg)", upgraded_cpp)
            self.assertIn("void FlutterWindow::RequestShutdownAndDestroy(HWND hwnd)", upgraded_cpp)
            self.assertIn("wakelock_channel_ = std::make_unique<", upgraded_cpp)
            self.assertNotIn("wakelock_channel.SetMethodCallHandler(", upgraded_cpp)
            self.assertIn("this->ShowInitialWindow();", upgraded_cpp)
            self.assertNotIn("SetNextFrameCallback([&]() {", upgraded_cpp)
            self.assertIn("if (is_shutting_down_ || exit_requested_)", upgraded_cpp)
            self.assertIn("window.Destroy();", upgraded_main)
        finally:
            prepare_platform.ROOT = orig_root

    def test_incremental_upgrade_from_legacy_071_runner_fixture_is_complete_and_idempotent(self) -> None:
        """Always runs even on CI shallow checkouts without historical git tags."""
        legacy_fw_h = SAMPLE_FW_H.replace(
            "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
            "  bool AddTrayIcon(const std::wstring& tooltip);\n"
            "  void RemoveTrayIcon();\n"
            "  void RestoreFromTray();\n"
            "  void ShowTrayContextMenu(HWND hwnd);\n"
            "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
            "  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;\n"
            "  NOTIFYICONDATAW tray_data_{};\n"
            "  bool tray_icon_added_ = false;\n"
            "  UINT taskbar_created_msg_ = 0;",
        )
        legacy_fw_cpp = SAMPLE_FW_CPP.replace(
            "  RegisterPlugins(flutter_controller_->engine());",
            '  RegisterPlugins(flutter_controller_->engine());\n'
            '  flutter::MethodChannel<flutter::EncodableValue> wakelock_channel(\n'
            '      flutter_controller_->engine()->messenger(), "marco_movie/wakelock",\n'
            '      &flutter::StandardMethodCodec::GetInstance());\n'
            '  wakelock_channel.SetMethodCallHandler(\n'
            '      [](const flutter::MethodCall<flutter::EncodableValue>& call,\n'
            '         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {\n'
            '        result->Success();\n'
            '      });\n'
            '  taskbar_created_msg_ = ::RegisterWindowMessageW(L"TaskbarCreated");\n'
            '  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(\n'
            '      flutter_controller_->engine()->messenger(), "marco_movie/windows_tray",\n'
            '      &flutter::StandardMethodCodec::GetInstance());\n'
            '  tray_channel_->SetMethodCallHandler(\n'
            '      [this](const flutter::MethodCall<flutter::EncodableValue>& call,\n'
            '             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {\n'
            '        if (call.method_name() == "removeTray") {\n'
            '          RemoveTrayIcon();\n'
            '          result->Success(flutter::EncodableValue(true));\n'
            '        } else {\n'
            '          result->NotImplemented();\n'
            '        }\n'
            '      });',
        ).replace(
            "void FlutterWindow::OnDestroy() {",
            "void FlutterWindow::OnDestroy() {\n"
            "  RemoveTrayIcon();\n"
            "  tray_channel_.reset();",
        )
        with tempfile.TemporaryDirectory() as tmp:
            fake_root = Path(tmp) / "flutter"
            win_runner = fake_root / "windows" / "runner"
            (win_runner / "resources").mkdir(parents=True, exist_ok=True)
            (win_runner / "main.cpp").write_text(SAMPLE_MAIN_CPP, encoding="utf-8")
            (win_runner / "win32_window.h").write_text(SAMPLE_W32_H, encoding="utf-8")
            (win_runner / "win32_window.cpp").write_text(SAMPLE_W32_CPP, encoding="utf-8")
            (win_runner / "flutter_window.h").write_text(legacy_fw_h, encoding="utf-8")
            (win_runner / "flutter_window.cpp").write_text(legacy_fw_cpp, encoding="utf-8")
            (win_runner / "CMakeLists.txt").write_text(SAMPLE_CMAKE, encoding="utf-8")
            self._assert_upgraded_runner_complete_and_idempotent(fake_root)

    def test_incremental_upgrade_from_windows_v071_runner_is_complete_and_idempotent(self) -> None:
        repo_root = Path(__file__).resolve().parent.parent
        try:
            old_script = subprocess.check_output(
                ["git", "show", "windows-v0.7.1:flutter/prepare_platform.py"],
                cwd=repo_root,
                stderr=subprocess.DEVNULL,
            ).decode("utf-8")
        except (subprocess.CalledProcessError, FileNotFoundError):
            self.skipTest("windows-v0.7.1 git tag not available in shallow checkout")
        with tempfile.TemporaryDirectory() as tmp:
            fake_root = Path(tmp) / "flutter"
            win_runner = fake_root / "windows" / "runner"
            (win_runner / "resources").mkdir(parents=True, exist_ok=True)
            (win_runner / "main.cpp").write_text(SAMPLE_MAIN_CPP, encoding="utf-8")
            (win_runner / "win32_window.h").write_text(SAMPLE_W32_H, encoding="utf-8")
            (win_runner / "win32_window.cpp").write_text(SAMPLE_W32_CPP, encoding="utf-8")
            (win_runner / "flutter_window.h").write_text(SAMPLE_FW_H, encoding="utf-8")
            (win_runner / "flutter_window.cpp").write_text(SAMPLE_FW_CPP, encoding="utf-8")
            (win_runner / "CMakeLists.txt").write_text(SAMPLE_CMAKE, encoding="utf-8")

            # First apply windows-v0.7.1 runner patching block.
            start = old_script.index("    win_main = win_runner /")
            end = old_script.index("    win_runner_cmake = win_runner /", start)
            exec(textwrap.dedent(old_script[start:end]), {"win_runner": win_runner, "re": re})
            self._assert_upgraded_runner_complete_and_idempotent(fake_root)

    def _run_windows_patch(self, fake_root: Path) -> None:
        # Execute prepare_platform.main() with real brand assets / python scripts untouched by
        # copying minimal required files into temp repo layout or calling main directly.
        real_root = Path(__file__).resolve().parent
        # Copy logo only if present so _write_windows_ico runs cleanly.
        orig_logo = prepare_platform.LOGO_MARK
        orig_repo = prepare_platform.REPO_ROOT
        orig_check_html = getattr(prepare_platform, "check_python_html", None)
        fake_repo = fake_root.parent
        (fake_repo / "scripts").mkdir(parents=True, exist_ok=True)
        # Keep real LOGO_MARK & REPO_ROOT for read-only asset checks, only override ROOT.
        # Ensure flutter/assets exists in temp so copies stay inside temp.
        (fake_root / "assets").mkdir(parents=True, exist_ok=True)
        (fake_root / "windows_native").mkdir(parents=True, exist_ok=True)
        for src in (real_root / "windows_native").glob("*"):
            if src.is_file():
                shutil.copy2(src, fake_root / "windows_native" / src.name)
        brand_win_src = real_root / "brand" / "windows"
        brand_win_dst = fake_root / "brand" / "windows"
        if brand_win_src.is_dir() and not brand_win_dst.exists():
            shutil.copytree(brand_win_src, brand_win_dst)
        try:
            prepare_platform.main()
        finally:
            prepare_platform.LOGO_MARK = orig_logo
            prepare_platform.REPO_ROOT = orig_repo


if __name__ == "__main__":
    unittest.main()
