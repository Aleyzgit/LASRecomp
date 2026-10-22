# System fonts

The game draws its text with the Switch's built-in system font, which isn't part of the game files.
Without it, LAS Recomp uses the bundled BIZ UDPGothic (Morisawa's free font from the same universal-design gothic
family as the Switch's UD Shin Go, `third_party/fonts/BIZUDPGothic`), then system fonts (Hiragino Sans, Yu Gothic,
Arial, DejaVu Sans). Any substitute is given the Switch font's vertical metrics, so its text comes out the same size.

For the exact look, put your own copies of the system fonts here:

- `nintendo_udsg-r_std_003.bfttf`: the main font (a `.ttf` with the same name, or spelled `nintendo_udsgr_std_003`, also works)
- `nintendo_ext_003.bfttf`: button glyphs (optional)

`LARECOMP_FONT=<file>` overrides everything (.ttf / .otf / .ttc / .bfttf).
