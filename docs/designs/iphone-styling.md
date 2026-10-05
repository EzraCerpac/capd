# Shared visual language

Capd's Mac search panel uses a fixed near-black canvas, faint raised surfaces and borders, light system text, and monospaced domains, ages, counts and tags. Its blue and purple accents sit beside orange text-source icons and blue link icons. Continuous 12-point panel corners and compact rows keep the library visually quiet.

`Packages/CapdDesignSystem` carries the portable palette, typography roles, spacing, radii and symbol tile. It imports SwiftUI only. The dark palette preserves the existing Mac values exactly. The light palette adapts the same roles for the iPhone's system appearance; increased contrast strengthens secondary text and borders. iPhone metadata uses secondary rather than tertiary text, since the Mac's small dim labels should not become essential mobile information.

The Mac keeps its fixed dark appearance, point-sized text, window geometry, keyboard actions and hover behavior. Its `NSImage` favicon loading stays in the Mac target. Shared styling does not own library records, sync state, images, permissions or platform navigation.

The iPhone keeps native navigation, sheets, forms and search. Its text uses Dynamic Type roles and its controls retain touch-sized targets. The library rows carry the Mac's source-icon/title/monospaced-metadata hierarchy with wrapping on narrow screens and larger text sizes. Source text and manual notes remain separate in the share extension and detail screen.

The Mac reference is an offscreen bitmap of the real `SearchView` with an injected `SearchEnvironment` and synthetic captures. It reads no live library or media and executes no capture, clipboard or network action. iPhone checks use disposable simulator data. These references establish the visual relationship without opening private captured content.

## Code boundary

The Mac `Theme` delegates its color values to `CapdPalette.dark`, its fixed-size monospaced font helper to `CapdTypography.mono`, and its panel radius to `CapdRadius.panel`. Its tile, favicon, tag, keyboard-hint and window implementations remain in the Mac target. The iPhone app and share extension consume the same package; their source rows and native forms use adaptive semantic colors and type.

At accessibility text sizes, the source tile moves above the text, long tags stack in rounded fields, and metadata can wrap without shrinking the selected text size. Display-only break opportunities help long machine strings fit; the original strings remain in storage and accessibility labels. A solid section header keeps scrolled content from showing through its title. No motion or platform interaction policy is added by the package.
