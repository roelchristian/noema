# Noema brand contract

`Sources/NoemaBrand/NoemaBrandPalette.swift` is the canonical colour source for
Noema's permanent identity. `NoemaBrandRole` defines the identity background,
primary orbit, satellites and nucleus. Every live mark and generated asset must
obtain these colours through this API.

| Role | Porcelain Iris (light) | Midnight Iris (dark) |
| --- | --- | --- |
| Identity background | `#F4F5FA` | `#101827` |
| Primary orbit | `#4358A8` | `#6478E8` |
| Satellites | `#287F9E` | `#61C6DF` |
| Nucleus | `#7767C2` | `#A49AF4` |

The palette takes explicit `dark` and `increasedContrast` inputs and never reads
application settings. Appearance selects a fixed variant. `ThemePreference` and
`MidnightIrisPalette` continue to control configurable interface surfaces, labels
and controls; Forest, Amber, Rose and System cannot replace brand tokens.
`ThemeRGB` is shared colour infrastructure, not a dependency on user theme state.

`token(_:)` always returns the canonical artwork value, including when Increase
Contrast is enabled. `foreground(_:against:minimumContrast:)` derives a colour
for a particular backing surface, defaulting to the identity background and 3:1
graphic contrast. All three canonical component colours already meet 3:1 on
their corresponding identity backgrounds. Increase Contrast raises the requested
minimum to 7:1. Corrections mix toward black or white only as much as needed;
they never modify the source tokens. For arbitrary midtone surfaces where 7:1
is mathematically unattainable, the API returns the strongest achievable
foreground. Text labels should use the interface's text roles and contrast rules.
The compact sidebar glyph can use a fixed 9:1 request against the identity
background in Increase Contrast mode: this margin maintains at least 7:1 across
all supported interface backgrounds and elevated surfaces, plus representative
native sidebar surfaces, without making its colours theme-dependent. Dynamic
material pixels vary with macOS and the content behind the window; the numeric
tests do not substitute for visual accessibility checks of those materials.

`OrbitGeometry` remains the sole definition of the silhouette, component
positions and proportions. This palette introduces no geometry or application
UI changes. See [README.md](README.md) for asset generation and packaging usage.
