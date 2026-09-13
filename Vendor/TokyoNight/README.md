# Tokyo Night palette provenance

Source: https://github.com/folke/tokyonight.nvim/tree/cdc07ac78467a233fd62c493de29a17e0cf2b2b6

Author: Folke Lemaitre. The two unmodified palette files are from extras/kitty at this pinned revision. The repository LICENSE is Apache-2.0 and is retained here verbatim. The generated palette headers additionally say MIT; those headers are retained unmodified, rather than silently relabelling their license. We distribute the root license and attribution with Snake.

Snake adaptations: convert foreground, background, cursor, selection and ANSI 0–15 values into Swift constants; no editor/plugin code is included. Day uses a pure white (#FFFFFF) background and cursor text instead of the upstream background, as requested for Snake's light appearance; the original palette files remain unmodified. Local semantic highlight accents are derived from the palette and darkened on Day as needed for readability, without changing upstream ANSI values. Only terminal surfaces and previews use these colors.
