# typed: false
# frozen_string_literal: true

# 上游 kitty + 本地补丁：padding_fill_strategy 支持按轴（垂直 水平）分别设置。
# 源码用上游发布包（自带预生成的 man/html 文档，无需 sphinx），补丁内嵌于文件末尾。
class Kitty < Formula
  desc "GPU-based terminal emulator with per-axis padding_fill_strategy (amzyang patch)"
  homepage "https://sw.kovidgoyal.net/kitty/"
  url "https://github.com/kovidgoyal/kitty/releases/download/v0.49.0/kitty-0.49.0.tar.xz"
  sha256 "b8b51901a4a5545a3b49241b6ea2050dbae509dfabd60ffcdb598a3a1344ec9a"
  version "0.49.0-amz.1"
  license "GPL-3.0-only"

  depends_on "go" => :build
  depends_on "pkgconf" => :build
  depends_on "simde" => :build
  depends_on :macos
  depends_on "harfbuzz"
  depends_on "lcms2"
  depends_on "libpng"
  depends_on "openssl@3"
  depends_on "python@3.14"
  depends_on "xxhash"
  depends_on "zlib"

  # slangc：编译内置 shader（构建期）与用户 custom_shaders（运行期）都需要；homebrew-core 无此包，用上游预编译产物。
  on_arm do
    resource "slang" do
      url "https://github.com/shader-slang/slang/releases/download/v2026.14.1/slang-2026.14.1-macos-aarch64.tar.gz"
      sha256 "92da7ab6226dd951037cd85397f830ae78fe40fbbb8928882e0b2654e468fdd4"
    end
  end
  on_intel do
    resource "slang" do
      url "https://github.com/shader-slang/slang/releases/download/v2026.14.1/slang-2026.14.1-macos-x86_64.tar.gz"
      sha256 "adc5e179f5584ca572293e93612df9f0b6be8a46dcb53622238efc7a62b1da2f"
    end
  end

  # setup.py 要求 Symbols Nerd Font Mono 在 fonts/ 或系统字体目录；沙箱内 HOME 是临时目录，直接放进 fonts/。
  resource "nerd-font" do
    url "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.tar.xz"
    sha256 "01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996"
  end

  patch :DATA

  def install
    (libexec/"slang").install resource("slang")
    resource("nerd-font").stage { (buildpath/"fonts").install "SymbolsNerdFontMono-Regular.ttf" }

    slangc = libexec/"slang/bin/slangc"
    # 从 Dock 启动的 kitty.app 没有 Homebrew PATH，把 slangc 的默认路径写死进去。
    inreplace "kitty/constants.py", "os.environ.get('SLANGC', 'slangc')", "os.environ.get('SLANGC', '#{slangc}')"
    ENV["SLANGC"] = slangc
    ENV["GOCACHE"] = buildpath/"gocache"
    ENV["GOMODCACHE"] = buildpath/"gomodcache"
    ENV.prepend_path "PKG_CONFIG_PATH", Formula["zlib"].opt_lib/"pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", Formula["openssl@3"].opt_lib/"pkgconfig"

    python = Formula["python@3.14"].opt_bin/"python3.14"
    # build 动作先产出 kitten 与编译后的 shaders，kitty.app 打包步骤直接取用它们。
    system python, "setup.py", "build"
    system python, "setup.py", "kitty.app", "--update-check-interval=0"

    prefix.install "kitty.app"
    system "codesign", "--force", "--deep", "--sign", "-", prefix/"kitty.app"
    bin.write_exec_script prefix/"kitty.app/Contents/MacOS/kitty"
    bin.write_exec_script prefix/"kitty.app/Contents/MacOS/kitten"
  end

  def caveats
    <<~EOS
      kitty.app 在 #{opt_prefix}/kitty.app，链接到 Applications 后可从 Dock / Spotlight 启动：
        ln -sfn #{opt_prefix}/kitty.app /Applications/kitty.app
      与官方 cask `kitty` 互斥，安装前先 `brew uninstall --cask kitty`。
      ad-hoc 签名：macOS 通知（notify_on_cmd_finish）不可用，升级后需重新授予 TCC 权限。
    EOS
  end

  test do
    assert_match "kitty 0.49.0", shell_output("#{bin}/kitty --version")
    check = "from kitty.config import load_config; " \
            "o = load_config(overrides=['padding_fill_strategy background neighboring_cell']); " \
            "assert o.padding_fill_strategy == ('background', 'neighboring_cell'), o.padding_fill_strategy"
    system bin/"kitty", "+runpy", check
  end
end

__END__
diff --git a/kitty/options/definition.py b/kitty/options/definition.py
index c5e3a4..194ed 100644
--- a/kitty/options/definition.py
+++ b/kitty/options/definition.py
@@ -1793,8 +1793,8 @@
 opt(
     'padding_fill_strategy',
     'background',
-    choices=('background', 'neighboring_cell'),
-    ctype='padding_fill_strategy',
+    option_type='padding_fill_strategy',
+    ctype='!padding_fill_strategy',
     long_text="""
 When the window size is not an exact multiple of the cell size, thin strips of
 compensatory padding are added at the window edges (see
@@ -1803,7 +1803,11 @@
 background color of the cell adjacent to it, which looks best with full screen
 applications such as editors that have differently colored border cells. A value
 of :code:`background` colors the strips using the window background
-color. Note that this only affects the compensatory padding, the intentional
+color. A single value applies to all four edges. Two values set the vertical
+(top and bottom) and the horizontal (left and right) strips separately, for
+example :code:`background neighboring_cell` extends cells sideways only, which
+keeps powerline glyphs in a status line intact while still filling the side
+strips. Note that this only affects the compensatory padding, the intentional
 padding from :opt:`window_padding_width` is always drawn using the background
 color.
 """,
diff --git a/kitty/options/parse.py b/kitty/options/parse.py
index 92069..4121d 100644
--- a/kitty/options/parse.py
+++ b/kitty/options/parse.py
@@ -16,16 +16,16 @@
     deprecated_macos_show_window_title_in_menubar_alias, deprecated_scrollback_indicator_opacity,
     deprecated_send_text, disable_ligatures, edge_width, env, filter_notification, font_features,
     hide_window_decorations, macos_option_as_alt, macos_titlebar_color, menu_map, modify_font,
-    mouse_hide_wait, narrow_symbols, notify_on_cmd_finish, optional_edge_width, parse_font_spec,
-    parse_map, parse_mouse_map, paste_actions, pointer_shape_when_dragging, remap_modifiers,
-    remote_control_password, resize_debounce_time, scrollback_lines, scrollback_pager_history_size,
-    scrollbar_color, shell_integration, show_hyperlink_targets, store_multiple, symbol_map,
-    tab_activity_symbol, tab_bar_edge, tab_bar_margin_height, tab_bar_min_tabs, tab_fade,
-    tab_font_style, tab_separator, tab_title_template, tab_title_wrap, text_fg_override_threshold,
-    titlebar_color, to_cursor_shape, to_cursor_unfocused_shape, to_font_size, to_layout_names,
-    to_modifiers, transparent_background_colors, underline_exclusion, url_prefixes, url_style,
-    visual_bell_duration, visual_window_select_characters, window_border_width, window_logo_scale,
-    window_size
+    mouse_hide_wait, narrow_symbols, notify_on_cmd_finish, optional_edge_width, padding_fill_strategy,
+    parse_font_spec, parse_map, parse_mouse_map, paste_actions, pointer_shape_when_dragging,
+    remap_modifiers, remote_control_password, resize_debounce_time, scrollback_lines,
+    scrollback_pager_history_size, scrollbar_color, shell_integration, show_hyperlink_targets,
+    store_multiple, symbol_map, tab_activity_symbol, tab_bar_edge, tab_bar_margin_height,
+    tab_bar_min_tabs, tab_fade, tab_font_style, tab_separator, tab_title_template, tab_title_wrap,
+    text_fg_override_threshold, titlebar_color, to_cursor_shape, to_cursor_unfocused_shape,
+    to_font_size, to_layout_names, to_modifiers, transparent_background_colors, underline_exclusion,
+    url_prefixes, url_style, visual_bell_duration, visual_window_select_characters, window_border_width,
+    window_logo_scale, window_size
 )


@@ -1194,12 +1194,7 @@ def open_url_with(self, val: str, ans: dict[str, typing.Any]) -> None:
         ans['open_url_with'] = to_cmdline(val)

     def padding_fill_strategy(self, val: str, ans: dict[str, typing.Any]) -> None:
-        val = val.lower()
-        if val not in self.choices_for_padding_fill_strategy:
-            raise ValueError(f"The value {val} is not a valid choice for padding_fill_strategy")
-        ans["padding_fill_strategy"] = val
-
-    choices_for_padding_fill_strategy = frozenset(('background', 'neighboring_cell'))
+        ans['padding_fill_strategy'] = padding_fill_strategy(val)

     def palette_generate(self, val: str, ans: dict[str, typing.Any]) -> None:
         val = val.lower()
diff --git a/kitty/options/to-c-generated.h b/kitty/options/to-c-generated.h
index 21a0f..15ca 100644
--- a/kitty/options/to-c-generated.h
+++ b/kitty/options/to-c-generated.h
@@ -4,6 +4,7 @@
 #include "to-c.h"


+
 static void
 convert_from_python_font_size(PyObject *val, Options *opts) {
     opts->font_size = PyFloat_AsDouble(val);
@@ -877,7 +878,7 @@ convert_from_opts_linux_bell_theme(PyObject *py_opts, Options *opts) {

 static void
 convert_from_python_padding_fill_strategy(PyObject *val, Options *opts) {
-    opts->padding_fill_strategy = padding_fill_strategy(val);
+    padding_fill_strategy(val, opts);
 }

 static void
diff --git a/kitty/options/to-c.h b/kitty/options/to-c.h
index 45f9c..b64fb 100644
--- a/kitty/options/to-c.h
+++ b/kitty/options/to-c.h
@@ -159,11 +159,17 @@ bglayout(PyObject *layout_name) {
 }

 static inline PaddingFillStrategy
-padding_fill_strategy(PyObject *val) {
+padding_fill_strategy_from_name(PyObject *val) {
     const char *name = PyUnicode_AsUTF8(val);
     return name[0] == 'n' ? PADDING_FILL_NEIGHBORING_CELL : PADDING_FILL_BACKGROUND;
 }

+static inline void
+padding_fill_strategy(PyObject *val, Options *opts) {
+    opts->padding_fill_strategy_vertical = padding_fill_strategy_from_name(PyTuple_GET_ITEM(val, 0));
+    opts->padding_fill_strategy_horizontal = padding_fill_strategy_from_name(PyTuple_GET_ITEM(val, 1));
+}
+
 static inline ImageAnchorPosition
 bganchor(PyObject *anchor_name) {
     const char *name = PyUnicode_AsUTF8(anchor_name);
diff --git a/kitty/options/types.py b/kitty/options/types.py
index e35e9..b7bba6 100644
--- a/kitty/options/types.py
+++ b/kitty/options/types.py
@@ -26,7 +26,6 @@
 choices_for_linux_display_server = typing.Literal['auto', 'wayland', 'x11']
 choices_for_macos_colorspace = typing.Literal['srgb', 'default', 'displayp3']
 choices_for_macos_show_window_title_in = typing.Literal['all', 'menubar', 'none', 'window']
-choices_for_padding_fill_strategy = typing.Literal['background', 'neighboring_cell']
 choices_for_palette_generate = typing.Literal['fixed', 'semantic', 'legacy']
 choices_for_placement_strategy = typing.Literal['top-left', 'top', 'top-right', 'left', 'center', 'right', 'bottom-left', 'bottom', 'bottom-right']
 choices_for_pointer_shape_when_grabbed = choices_for_default_pointer_shape
@@ -635,7 +634,7 @@ class Options:
     mouse_hide_wait: MouseHideWait = MouseHideWait(hide_wait=0.0, show_wait=0.0, show_threshold=40, scroll_show=True) if is_macos else MouseHideWait(hide_wait=3.0, show_wait=0.0, show_threshold=40, scroll_show=True)
     notify_on_cmd_finish: NotifyOnCmdFinish = NotifyOnCmdFinish(when='never', duration=5.0, action='notify', cmdline=(), clear_on=('focus', 'next'))
     open_url_with: list[str] = ['default']
-    padding_fill_strategy: choices_for_padding_fill_strategy = 'background'
+    padding_fill_strategy: tuple[str, str] = ('background', 'background')
     palette_generate: choices_for_palette_generate = 'fixed'
     paste_actions: frozenset[str] = frozenset({'confirm', 'quote-urls-at-prompt'})
     pixel_scroll: bool = True
diff --git a/kitty/options/utils.py b/kitty/options/utils.py
index 2a49c..8b34d 100644
--- a/kitty/options/utils.py
+++ b/kitty/options/utils.py
@@ -680,6 +680,16 @@ def cursor_trail_start_threshold(x: str) -> tuple[int, int]:
     raise ValueError(f'cursor_trail_start_threshold must have 1 or 2 values, got: {x!r}')


+def padding_fill_strategy(x: str) -> tuple[str, str]:
+    parts = x.lower().split()
+    if len(parts) not in (1, 2):
+        raise ValueError(f'padding_fill_strategy must have 1 or 2 values, got: {x!r}')
+    for p in parts:
+        if p not in ('background', 'neighboring_cell'):
+            raise ValueError(f'The value {p} is not a valid choice for padding_fill_strategy')
+    return parts[0], parts[-1]
+
+
 def scrollback_lines(x: str) -> int:
     ans = int(x)
     if ans < 0:
diff --git a/kitty/shaders.c b/kitty/shaders.c
index 72903..c56bd 100644
--- a/kitty/shaders.c
+++ b/kitty/shaders.c
@@ -1860,9 +1860,11 @@ draw_window_padding(const UIRenderData *ui, Window *window, ssize_t vao_idx, boo
     // and one the vertical pair (left+right). Each draw packs its strip cells into
     // a dedicated buffer so the VAO needs no per-strip reconfiguration. The shader
     // selects per-strip geometry and cell indices branch-free via lerp.
-    if (!window || OPT(padding_fill_strategy) != PADDING_FILL_NEIGHBORING_CELL) return;
-    const unsigned int cl = window->size_mismatch_padding.left, ct = window->size_mismatch_padding.top, cr = window->size_mismatch_padding.right,
-                       cb = window->size_mismatch_padding.bottom;
+    if (!window) return;
+    unsigned int cl = window->size_mismatch_padding.left, ct = window->size_mismatch_padding.top, cr = window->size_mismatch_padding.right,
+                 cb = window->size_mismatch_padding.bottom;
+    if (OPT(padding_fill_strategy_vertical) != PADDING_FILL_NEIGHBORING_CELL) ct = cb = 0;
+    if (OPT(padding_fill_strategy_horizontal) != PADDING_FILL_NEIGHBORING_CELL) cl = cr = 0;
     if (!(cl | ct | cr | cb)) return;
     Screen *screen = ui->screen;
     const unsigned int columns = screen->columns, lines = screen->lines;
diff --git a/kitty/state.h b/kitty/state.h
index 08aaf..44916 100644
--- a/kitty/state.h
+++ b/kitty/state.h
@@ -107,7 +107,7 @@ typedef struct Options {
         unsigned generation;
     } background_images;
     BackgroundImageLayout background_image_layout;
-    PaddingFillStrategy padding_fill_strategy;
+    PaddingFillStrategy padding_fill_strategy_vertical, padding_fill_strategy_horizontal;
     ImageAnchorPosition window_logo_position;
     bool background_image_linear;
     float background_tint, background_tint_gaps, window_logo_alpha;
