# MK2 FreeType Typography

Status: implemented for `KontrolSurfaceKit2` exploration and ready for hardware evaluation
through `MK2FreeTypeDemo`.

## Scope

The MK2 pixel-display stack now has two text rendering paths:

- **Bitmap fonts**: `BitmapLabel`, `SurfaceFont`, and `MK2PixelFrame.drawText(...)`.
  This remains the default for tracker/grid surfaces and any dense UI that must stay
  bitmap-sharp.
- **FreeType fonts**: `FreeTypeTextRenderer`, `FreeTypeTextStyle`,
  `FreeTypeFontCatalog`, and `FreeTypeRasterMode`. This path is for calmer, larger
  surfaces such as global dialogs, browser/settings views, selection lists, long text,
  and icon-font-style symbol work.

These paths are independent. Integrating FreeType does not put FreeType in the bitmap
font hot path; existing bitmap labels still draw through atlas row bits and bulk
`MK2PixelFrame.fill(...)` runs.

## Bundled Fonts

`KontrolSurfaceKit2` bundles exploratory font resources under
`Sources/KontrolSurfaceKit2/Resources/Fonts/`:

- Inter variable TTF
- IBM Plex Sans OTF: Light, Regular, Text, Medium, SemiBold, Bold
- IBM Plex Sans Condensed OTF: Light, Regular, Text, Medium, SemiBold, Bold

The global swap point is `FreeTypeFontCatalog.exploratory`. Add or replace families there
rather than scattering resource names through UI code. Inter uses its variable `wght` axis;
Plex uses static OTF cuts. Collection files were preferred, but the local checkouts did
not provide relevant `.ttc`/`.otc` files for these families.

## Raster Modes

`FreeTypeRasterMode` exposes hardware-checkable modes:

- `grayscaleHinted` (`Gray hinted`) — recommended default for the MK2 OLED/RGB565 path.
- `grayscaleLightHinted` (`Gray light`) — often calmer at mid sizes.
- `grayscaleUnhinted` (`Gray unhinted`) — useful to judge native outline shape.
- `monochromeHinted` (`Mono hinted`) — comparison mode; no partial coverage.

LCD/subpixel rendering is intentionally not enabled. The MK2 path renders into an RGB565
framebuffer and the OLED subpixel layout is not a stable RGB-stripe contract. Subpixel AA
would risk colour fringes and panel-orientation artifacts; grayscale coverage is the robust
choice.

## Demo

Build:

```bash
make mk2-freetype-demo-build
```

Run on hardware through the daemon:

```bash
make mk2-freetype-demo
```

Release build/run:

```bash
make mk2-freetype-demo-build-release
make mk2-freetype-demo-release
```

The demo prints its full hardware-control help at startup. Current controls:

- `Page Left` / `Page Right`: previous / next font family
- `F1`-`F3`: selected family state; active family is bright blue, other available
  families are dim
- `Browser` / `Instance`: previous / next weight
- `Preset Down` / `Preset Up`: smaller / larger pixel size
- `Plugin`: cycle raster mode
- `Mixer`: cycle sample text

Only one MK2 surface client should own the displays at a time. Stop `MK2WidgetLabDemo`,
`MK2SurfaceDemo`, Paulinche, or another client before judging `MK2FreeTypeDemo`; registering
a new client evicts the previous session.

## Performance Notes

Bitmap text performance is covered by `PixelPipelinePerfTests`, especially the
`drawText 60 chars scale 3` line. FreeType rendering is separate from that path and is
covered by `FreeTypeTextRendererTests`.

Recommended checks after touching this area:

```bash
swift build --product MK2FreeTypeDemo
swift test --filter 'FreeTypeTextRendererTests|SurfaceFontMetricsTests|BitmapTextTests|PixelPipelinePerfTests'
swift test
git diff --check
```

Use `PixelPipelinePerfTests` as the regression check for the user-facing question "did
bitmap rendering get slower?" A FreeType-only change should not move the bitmap drawText
timing except for normal machine noise.

