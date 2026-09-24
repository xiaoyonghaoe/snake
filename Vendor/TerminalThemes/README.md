# Built-in terminal palette provenance

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
