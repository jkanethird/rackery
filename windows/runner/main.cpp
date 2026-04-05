#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
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
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"rackery", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Show the window BEFORE initialising Flutter.  This gives external window
  // managers (e.g. PowerToys FancyZones) a chance to reposition / resize the
  // window so that the Flutter rendering surface is created at the correct
  // final dimensions.
  window.Show();

  // Drain any pending messages that the Show / FancyZones repositioning
  // may have enqueued (WM_SIZE, WM_MOVE, WM_WINDOWPOSCHANGED, etc.)
  // so the window is at its final geometry before we create the engine.
  MSG pending;
  while (::PeekMessage(&pending, nullptr, 0, 0, PM_REMOVE)) {
    ::TranslateMessage(&pending);
    ::DispatchMessage(&pending);
  }

  // Now create the Flutter engine at the window's actual current size.
  if (!window.InitFlutterEngine()) {
    return EXIT_FAILURE;
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
