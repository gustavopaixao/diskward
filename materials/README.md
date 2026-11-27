# Diskward assets

- App icon: 1024×1024 RGBA PNG, extracted from approved concept board (~324px source artwork) and upscaled. This is a prototype raster, not a native-resolution master.
- AppIcon.iconset: macOS standard 1x/2x PNG sizes.
- Menu bar: independent monochrome glyph, 18pt, 1x/2x/3x. Black template PNGs are the implementation assets; white versions are previews only. SVG source included.
- Assets.xcassets: ready-to-copy AppIcon and DiskwardMenuBar sets. Merge into existing catalog rather than replacing unrelated assets.

SwiftUI: `Image("DiskwardMenuBar").renderingMode(.template)`; for NSStatusItem, set `NSImage.isTemplate = true`. Set app icon asset name to AppIcon.

Palette: navy #0F2D4A, teal #0B6E7A, mint #34D399, light #F7F9FC, dark #121A24. Use SF Pro and SF Mono for technical details.

Verify actual Dock and menu bar rendering in Xcode at 1x/2x, including light/dark appearance. The app icon is the dimensional direction; small sizes are scaled, not individually redrawn.
