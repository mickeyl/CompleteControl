# MK2 FreeType Typography

Status: implemented for `KontrolSurfaceKit2`; the first production typography choice is
locked and can be checked on hardware through `MK2WidgetLabDemo` Unit A.

## Scope

The MK2 pixel-display stack now has two text rendering paths:

- **Bitmap fonts**: `BitmapLabel`, `SurfaceFont`, and `MK2PixelFrame.drawText(...)`.
  This remains the default for tracker/grid surfaces and any dense UI that must stay
  bitmap-sharp.
- **FreeType fonts**: `FreeTypeTextRenderer`, `FreeTypeTextStyle`,
  `FreeTypeFontCatalog`, and `FreeTypeRasterMode`. This path is for calmer, larger
  surfaces such as global dialogs, browser/settings views, selection lists, long text,
  and icon-font-style symbol work. Proportional text runs are shaped by HarfBuzz before
  FreeType rasterization, so standard ligatures and OpenType positioning can apply.

These paths are independent. Integrating FreeType does not put FreeType in the bitmap
font hot path; existing bitmap labels still draw through atlas row bits and bulk
`MK2PixelFrame.fill(...)` runs.

The fixed-pitch `SurfaceFont` path is intentionally unshaped even though it now lowers
to JetBrains Mono through FreeType. Tracker/grid text must keep one scalar per fixed
cell, so ligatures are not enabled there.

## Production Fonts

`KontrolSurfaceKit2` bundles production font resources under
`Sources/KontrolSurfaceKit2/Resources/Fonts/`:

- IBM Plex Sans Condensed Regular OTF for body text.
- IBM Plex Sans Condensed Medium OTF for title text.
- Font Awesome 7 Pro Light OTF for icons.

The global swap point is `FreeTypeFontCatalog.production`. Add or replace families there
rather than scattering resource names through UI code. The legacy
`FreeTypeFontCatalog.exploratory` alias points at the same production catalog for source
compatibility.

Current text contract:

- Body: IBM Plex Sans Condensed Regular, 16 px.
- Caption: IBM Plex Sans Condensed Medium, 17 px, rendered uppercase for regular
  screen chrome such as header title/subtitle labels.
- Title: IBM Plex Sans Condensed Medium, 24 px.
- Icon: Font Awesome 7 Pro Light.
- Action-dialog icon size: 48 px.
- Raster: `FreeTypeRasterMode.grayscaleHinted`.

## Raster Modes

`FreeTypeRasterMode` still exposes hardware-checkable modes:

- `grayscaleHinted` (`Gray hinted`) — recommended default for the MK2 OLED/RGB565 path.
- `grayscaleLightHinted` (`Gray light`) — often calmer at mid sizes.
- `grayscaleUnhinted` (`Gray unhinted`) — useful to judge native outline shape.
- `monochromeHinted` (`Mono hinted`) — comparison mode; no partial coverage.

`MK2WidgetLabDemo` Unit A now renders with `grayscaleHinted` fixed because that is the chosen MK2
OLED default. LCD/subpixel rendering is intentionally not enabled. The MK2 path renders
into an RGB565 framebuffer and the OLED subpixel layout is not a stable RGB-stripe
contract. Subpixel AA would risk colour fringes and panel-orientation artifacts;
grayscale coverage is the robust choice.

## Demo

Build:

```bash
make mk2-widget-lab-demo-build
```

Run on hardware through the daemon:

```bash
make mk2-widget-lab-demo
```

Release build/run:

```bash
make mk2-widget-lab-demo-build-release
make mk2-widget-lab-demo-release
```

Legacy `make mk2-freetype-demo*` targets remain aliases to the Widget Lab targets.
Current controls:

- `F1`: select Unit A / Font Lab.
- `Instance`: cycle Surface Font, Typography, Font Awesome icon browser, and global
  action-dialog sub-demos.
- Main rotary: scroll the icon browser list by one icon.
- `4D Up` / `4D Down`: scroll the icon browser list by one visible page.
- `Page Left` / `Page Right`: previous / next icon.
- `Plugin` / `Mixer`: jump -16 / +16 icons; on the dialog page `Mixer` also cycles
  dialog copy and its default icon.
- `E8`: icon-browser list/grid/filter-list/filter-grid mode.
- `E5`: filtered icon-browser modes: first-letter filter.
- `Preset Down` / `Preset Up`: smaller / larger icon size.

Only one MK2 surface client should own the displays at a time. Stop `MK2WidgetLabDemo`,
`MK2SurfaceDemo`, Paulinche, or another client before judging the Widget Lab; registering
a new client evicts the previous session.

## Performance Notes

Bitmap text performance is covered by `PixelPipelinePerfTests`, especially the
`drawText 60 chars scale 3` line. FreeType rendering is separate from that path and is
covered by `FreeTypeTextRendererTests`.

Recommended checks after touching this area:

```bash
swift build --product MK2WidgetLabDemo
swift test --filter 'FreeTypeTextRendererTests|SurfaceFontMetricsTests|BitmapTextTests|PixelPipelinePerfTests'
swift test
git diff --check
```

Use `PixelPipelinePerfTests` as the regression check for the user-facing question "did
bitmap rendering get slower?" A FreeType-only change should not move the bitmap drawText
timing except for normal machine noise.
