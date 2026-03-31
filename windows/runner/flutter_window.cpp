#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

static const UINT_PTR kRedrawTimerId = 1;
static const int kRedrawTimerCount = 5;

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // Flutter engine creation is deferred to InitFlutterEngine() so that the
  // window can be shown and repositioned by external tools (e.g. PowerToys
  // FancyZones) before the rendering surface is created.
  return true;
}

bool FlutterWindow::InitFlutterEngine() {
  RECT frame = GetClientArea();

  // Create the Flutter view controller at the window's *current* client size.
  // Because the window has already been shown and repositioned, this size
  // matches the final on-screen dimensions.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Force an initial frame so content appears immediately.
  flutter_controller_->ForceRedraw();

  // The parent window was already shown (visible) before the Flutter child
  // HWND existed.  Windows does not automatically composite the newly-added
  // child into the visible parent, so we force a full invalidation + repaint.
  RedrawWindow(GetHandle(), nullptr, nullptr,
               RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);

  // Start a repeating timer as a safety net: ForceRedraw() only *schedules*
  // a frame — Flutter may not have actually rendered yet.  The timer ensures
  // we keep forcing repaints until Flutter has produced its first frame.
  redraw_timer_remaining_ = kRedrawTimerCount;
  SetTimer(GetHandle(), kRedrawTimerId, 200, nullptr);

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    KillTimer(GetHandle(), kRedrawTimerId);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle WM_SIZE before HandleTopLevelWindowProc, which may intercept it
  // and prevent the base class from resizing the child HWND.
  if (message == WM_SIZE && flutter_controller_) {
    // 1) Base class resizes the child HWND to match the parent.
    Win32Window::MessageHandler(hwnd, message, wparam, lparam);

    // 2) Notify Flutter about the top-level resize (surface resize, etc.)
    flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                  lparam);

    // 3) Force a new frame at the updated size.
    flutter_controller_->ForceRedraw();
    return 0;
  }

  // All other messages: let Flutter handle first.
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
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case WM_TIMER:
      if (wparam == kRedrawTimerId && flutter_controller_) {
        // Force-sync child HWND to current client area and repaint.
        HWND child = flutter_controller_->view()->GetNativeWindow();
        if (child) {
          RECT frame = GetClientArea();
          MoveWindow(child, frame.left, frame.top,
                     frame.right - frame.left, frame.bottom - frame.top,
                     TRUE);
          ShowWindow(child, SW_SHOW);
        }
        flutter_controller_->ForceRedraw();
        RedrawWindow(hwnd, nullptr, nullptr,
                     RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);

        if (--redraw_timer_remaining_ <= 0) {
          KillTimer(hwnd, kRedrawTimerId);
        }
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
