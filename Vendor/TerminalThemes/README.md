# Built-in terminal palette provenance

Ghostty Clear is based on `ghostty-org/ghostty` at commit
`a2e440396403385680008e456a741a7776091412`: `src/config/Config.zig`
(default `#282C34` background and `#FFFFFF` foreground) and
`src/terminal/color.zig` (`Name.default` ANSI colors). Ghostty is MIT-licensed;
its copyright is retained in `LICENSE`.

Snake's Ghostty Clear is an adaptation, not an exact upstream theme: dark ANSI
red, bright colors, white, and especially bright black/comments are raised for
at least 4.5:1 contrast on the default background. ANSI black remains `#1D1F21`
for terminal applications that use it as a background. The light version uses
white with darker text/colors. Cursor and selection colors are Snake choices.
No Ghostty renderer, font thickening or runtime minimum-contrast algorithm is
included. Remote 256-color and True Color requests remain unmodified.

The Catppuccin Latte/Mocha values in `TerminalTheme.swift` were transcribed from
`catppuccin/iterm` at commit `b2936a6e55270fcc55421b1bb7d5fd194a489591`
(`colors/catppuccin-latte.itermcolors` and `catppuccin-mocha.itermcolors`).

Gruvbox Light/Dark values came from `morhetz/gruvbox-contrib` at commit
`150e9ca30fcd679400dc388c24930e5ec8c98a9f`
(`iterm2/gruvbox-light.itermcolors` and `gruvbox-dark.itermcolors`), based on
the MIT/X11-licensed original `morhetz/gruvbox` palette.

Solarized Light/Dark values came from `altercation/solarized` at commit
`62f656a02f93c5190a8753159e34b385588d5ff3`
(`iterm2-colors-solarized/Solarized Light.itermcolors` and
`Solarized Dark.itermcolors`).

Snake changes every built-in **light** variant's terminal background to white.
Cursor text and/or selection colors were adjusted where needed to stay visible
on white. Solarized Dark foreground/cursor is raised to `#839496` for readable
contrast. Other dark values and ANSI 16-color tables retain the pinned source values.
Imported `.itermcolors` palettes are never white-background adapted.
