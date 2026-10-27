# System fonts

The game draws its text with the Switch's built-in system font, which isn't part of the game files.
Without it, LAS Recomp uses a system font on macOS and Windows (Hiragino Sans, Yu Gothic, Arial). On Linux it uses
the bundled BIZ UDPGothic (Morisawa's free font from the same universal-design gothic family as the Switch's UD Shin Go,
`third_party/fonts/BIZUDPGothic`), then DejaVu Sans; there any substitute is given the Switch font's vertical metrics,
so its text comes out the same size as on the console.

For the exact look, put your own copies of the system fonts here:

- `nintendo_udsg-r_std_003.bfttf`: the main font (a `.ttf` with the same name, or spelled `nintendo_udsgr_std_003`, also works)
- `nintendo_ext_003.bfttf`: button glyphs (optional)

`LARECOMP_FONT=<file>` overrides everything (.ttf / .otf / .ttc / .bfttf).

## Choosing a text font

In the Recomp settings (**Esc / F1 > Video > Game text font**), choose:

- **Automatic**: the existing behavior; imported Nintendo files first, then a substitute for the game language.
- **System fonts**: skip imported text fonts, keeping the files in place. Imported Nintendo button icons are kept.
- **A filename**: use that file from the data folder's `fonts/` for text. The right pane shows the family name,
  full filename, usual system substitute, and the font loaded for the current game boot. The environment variable
  `LARECOMP_FONT`, when set, takes priority and is reported there.

The setting is saved as `game_font = auto`, `system`, or the selected filename in `larecomp.ini`. It applies when
starting the game again (Recomp menu: Quit > Title screen, then Play again; or restart LAS Recomp). It does not change the Recomp menu's
own font. The menu currently supports English; the choice works with all eleven game languages. Choose a font
with glyphs for the language you play in.

The normal substitutes are Yu Gothic on Windows, Hiragino Sans W4 on macOS, and BIZ UDPGothic on Linux, with
fallbacks when those are unavailable. Chinese / Korean use their own language's system fonts, and Russian skips
Japanese fonts. The original Standard font is Morisawa UD Shin Go Regular; both
`nintendo_udsg-r_std_003.ttf` and `nintendo_udsgr_std_003.ttf` are recognized, along with their `.bfttf` forms.

### Importing a font

1. Open **Esc / F1 > Video**, then select **Import text font...**.
2. In the file picker, choose your `.ttf`, `.ttc` or `.bfttf` file. For the original Standard font,
   this is `nintendo_udsg-r_std_003` (or `nintendo_udsgr_std_003`) with a `.ttf` or `.bfttf` extension.
3. LAS Recomp copies the file into its data folder's `fonts/` and selects it automatically. It keeps the source
   file and never overwrites a different existing file with the same name. You can also copy files into `fonts/`
   yourself and select them using **Game text font**.
4. Choose **Quit > Title screen** in the Recomp menu, then **Play** again; or restart LAS Recomp. The description shows the font loaded for the new game boot.

Local `.ttf`, `.ttc` (first face) and `.bfttf` files can be selected. Only TrueType outlines are supported; CFF
OpenType fonts are omitted because the game's font engine cannot use them. A missing or unusable saved file is
shown with a warning and falls back to Automatic on the next boot. File selection never deletes imported fonts.
No proprietary fonts are included or downloaded by this feature.
