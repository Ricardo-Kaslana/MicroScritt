// Windows 桌面入口。
//
// 初始化 COM、加载 Dart 入口参数并创建主窗口;窗口标题固定为
// MicroScritt,其余行为沿用 Flutter Windows runner 模板。
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 主显示器工作区(已排除任务栏)内的居中偏置,单位是逻辑像素。
// Win32Window::Create 会按目标点所在显示器的 DPI 再缩放 origin 与 size,
// 所以这里统一给逻辑坐标;窗口比工作区还大时退回固定边距,避免左上角
// 被推到屏幕外、标题栏拖不动。
Win32Window::Point CenteredOrigin(const Win32Window::Size& size) {
  RECT work_area{};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0)) {
    return Win32Window::Point(10, 10);
  }

  // 进程为 PerMonitorV2 感知(runner.exe.manifest),工作区是物理像素,
  // 需按显示器 DPI(与 Create 同一来源)折算回逻辑像素才能和 size 比较。
  UINT dpi = FlutterDesktopGetDpiForMonitor(
      ::MonitorFromRect(&work_area, MONITOR_DEFAULTTONEAREST));
  if (dpi == 0) {
    dpi = 96;
  }
  const double scale = dpi / 96.0;
  const int work_width =
      static_cast<int>((work_area.right - work_area.left) / scale);
  const int work_height =
      static_cast<int>((work_area.bottom - work_area.top) / scale);

  // Create 把 origin 当作绝对坐标,主屏原点未必是 (0,0)(左侧还挂着副屏时),
  // 必须叠回工作区自身的逻辑原点,否则窗口会落到别的显示器上。
  const int origin_x = static_cast<int>(work_area.left / scale);
  const int origin_y = static_cast<int>(work_area.top / scale);
  const int x =
      origin_x + (work_width > static_cast<int>(size.width)
                      ? (work_width - static_cast<int>(size.width)) / 2
                      : 10);
  const int y =
      origin_y + (work_height > static_cast<int>(size.height)
                      ? (work_height - static_cast<int>(size.height)) / 2
                      : 10);
  return Win32Window::Point(x, y);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 附加到调用方控制台(如 `flutter run`);调试器中则新建控制台。
  // 以下模板注释沿用上游英文,避免与 flutter create 升级产生冲突。
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Size size(1280, 720);
  // 启动即居中于主显示器工作区。
  Win32Window::Point origin = CenteredOrigin(size);
  if (!window.Create(L"MicroScritt", origin, size)) {
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
