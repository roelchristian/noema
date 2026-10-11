# Noema design tokens and visual foundations

Current shared chrome contract

This contract gives shared application chrome a single presentation vocabulary. `NoemaTheme` remains the only appearance resolver. Native SwiftUI and AppKit controls retain their interaction, accessibility, sizing and system appearance behavior. Document typography, branding geometry, storage, sessions and serialization are outside this migration.

Choose tokens by semantic purpose, rather than numeric equality. Keep current exceptions and unresolved visual acceptance separate from automated test results.

## Ownership and naming contract

| Owner | Responsibility | Consumers |
| --- | --- | --- |
| `Sources/noema/Theme.swift` / `NoemaTheme` | Resolve all new interface colors against appearance, contrast, selected palette, full-palette setting and active/inactive state | Sidebar, workspace/library framing, inspector, custom chrome |
| `Sources/NoemaBrand/MidnightIris.swift` | Existing `ThemeRole`, selectable palette RGB values and contrast correction; compatibility retained | `NoemaTheme`, palette picker and existing editor rendering |
| `Sources/NoemaBrand/NoemaBrandPalette.swift`, `OrbitGeometry.swift` | Permanent identity colors and artwork geometry, independent of interface palette | `NoemaMark`, About artwork and app icon |
| `Sources/noema/DesignTokens.swift` / `NoemaTypography` | Named SwiftUI system text styles for interface hierarchy | Library/document chrome headings, navigation labels, inspector labels |
| `Sources/noema/DesignTokens.swift` / `NoemaSpacing` | Modest shared point scale | Shared stacks, headers and panel padding |
| `Sources/noema/DesignTokens.swift` / `NoemaMetrics` | Custom chrome geometry and density reference values | Custom navigation rows, search, tab groups and inspector framing |
| `EditorTypography.swift`, `BlockTextStorage.swift`, text-view components | User-configured document font, paragraph/block layout and text selection | Rich/plain editors, source reader and document decorations |
| SwiftUI / AppKit | Native control sizing, focus, selection, menus, sheets, alerts, vibrancy and progress animation | `Table`, `List`, `Form`, native buttons/pickers/text inputs and Quick Look |
| Component layout | Pane constraints, editorial alignment, optical offsets, specialized sheet size | Split panes, editor gutters, branding and command palette |

Types use the `Noema` prefix; properties and cases describe purpose (`selection`, `metadata`, `inspectorInset`), not RGB values or a particular component's current screenshot. Color resolution belongs in `NoemaTheme`, never in another settings store or view-level opacity calculation. Metrics do not read palette, appearance, persistence or vault state. A future density preference is explicitly deferred.

### Color API

`Theme.swift` exposes this interface while keeping existing `ThemeRole` methods available for document and brand consumers. The argument labels avoid ambiguous `.textPrimary` inference between the old and new role enums.

```swift
enum NoemaColorRole: CaseIterable, Sendable {
    case window, sidebar, canvas, inspector, elevated
    case selection, hover, pressed, separator
    case textPrimary, textSecondary, textTertiary, textOnSelection, disabledText
    case accent, destructive, focusRing
}

// Methods on the existing NoemaTheme:
func color(for role: NoemaColorRole, active: Bool = true) -> Color
func native(for role: NoemaColorRole, active: Bool = true) -> NSColor
func text(for role: NoemaColorRole = .textSecondary,
          on surface: NoemaColorRole = .canvas,
          active: Bool = true) -> Color
func nativeText(for role: NoemaColorRole = .textSecondary,
                on surface: NoemaColorRole = .canvas,
                active: Bool = true) -> NSColor
```

`text(for:on:)` resolves a foreground against its actual backing surface. Foreground callers use text/emphasis roles; `on:` callers use surface/state roles. A role parameter is not a request to change native controls' inherited foreground. New custom chrome calls the labeled API; legacy editor/palette consumers keep the existing API until separately reviewed.

`active` means the application window is active; it does not mean selected. Custom selection stays visible when inactive. Hover and pressed remain visually distinct from selection. Read active window state from the existing UI environment/AppKit as appropriate, rather than adding a preference. System colors remain dynamic; a resolved RGB snapshot must not be cached across appearance/accent/accessibility changes.

| Role | Purpose and first consumers | System resolution guidance | Full palette guidance |
| --- | --- | --- | --- |
| `window` | Root workspace; locked and no-vault backgrounds | `windowBackgroundColor` | Existing `.background` |
| `sidebar` | Navigation backing in `ContentView` | Retain `SidebarMaterialView` vibrancy; fallback `windowBackgroundColor` | Existing palette background |
| `canvas` | Library/reading backing, outside native `Table` internals | `textBackgroundColor` | Existing background or elevated surface, consistent with foreground resolution |
| `inspector` | `InspectorContainer` contextual backing | `windowBackgroundColor` | Existing palette background |
| `elevated` | Custom search/group/container backing | `controlBackgroundColor` or `textBackgroundColor` | Existing `.surfaceElevated` |
| `selection` | Custom sidebar rows and inspector/sidebar tabs | Active/inactive native selection colors | Palette-derived fill with contrast-correct selected foreground |
| `hover` | Pointer highlight for custom rows/actions | Subtle dynamic control fill | Restrained surface/accent mixture; never reuse selected fill |
| `pressed` | Custom button down state | Dynamic pressed/selected-control fill | Stronger than hover, with legible foreground |
| `separator` | Structural boundaries and custom outlines | `separatorColor`; strengthen when Increase Contrast needs it | Existing `.border`, contrast aware |
| `textPrimary` | Navigation labels, library/inspector headings and values | `labelColor` | Existing `.textPrimary`, corrected against actual surface |
| `textSecondary` | Metadata, captions and supporting labels | `secondaryLabelColor` | Existing `.textMuted`, corrected against actual surface |
| `textTertiary` | Relative dates and keyboard hints | `tertiaryLabelColor`; increased contrast must remain readable | Derived muted tone, corrected for readability |
| `textOnSelection` | Selected custom navigation text/icons | Match active/inactive selection foreground to fill | Correct against `selection`, never assume white |
| `disabledText` | Disabled labels in custom controls only | `disabledControlTextColor` | Dynamic native disabled text or readable derived muted tone |
| `accent` | Custom active-tab emphasis, focus-adjacent icons | `controlAccentColor` | Existing palette control accent |
| `destructive` | Custom error notice/text; native action roles stay native | `systemRed` | Dynamic red or contrast-correct equivalent |
| `focusRing` | Focus indicator on custom plain search/tab/action controls | `keyboardFocusIndicatorColor` | Dynamic native focus ring remains appropriate |

No fixed interface RGB values are introduced in views. Existing permanent identity RGB values are approved exceptions. Opacity/mixing may be used centrally to derive state colors, but selected text must be checked against the composited backing. Increased contrast must not merely change opacity without checking resulting readability and boundaries.

A global two-level foreground style must remain removed or limited to prevent nested native controls from inheriting palette foregrounds that mismatch native selected/prominent fills. Scoped text styling and root surface/tint resolution are allowed. Existing system color/accessibility notification invalidation stays in the theme modifier.

### Typography and spacing API

`DesignTokens.swift` exposes named static `Font` properties. Use platform text styles so accessibility scaling remains available where macOS supports it. Preserve editorial typography via `EditorTypography` and its persisted family/size settings.

| `NoemaTypography` property | Initial system style | Purpose and consumer |
| --- | --- | --- |
| `documentTitle` | `.title.weight(.semibold)` | Document title chrome in `ContentView`; body/block headings are excluded |
| `libraryTitle` | `.title2.weight(.bold)` | Sources, Pages, Trash and search collection headings |
| `sectionHeader` | `.headline.weight(.semibold)` | Inspector panel headings |
| `navigation` | `.callout` | Sidebar row labels and custom navigation icons |
| `navigationEmphasis` | `.callout.weight(.medium)` | Selected tab or vault label |
| `interface` | `.callout` | Property values and custom search text |
| `interfaceEmphasis` | `.callout.weight(.medium)` | Link/source row titles and actions |
| `metadata` | `.caption` | Dates, counts, inspector supporting text |
| `metadataEmphasis` | `.caption.weight(.medium)` | Count badges and emphasized metadata |
| `caption` | `.caption2` | Keyboard hints and minor icon annotations |
| `sidebarSection` | `.caption.weight(.semibold)` | Recent/All Pages uppercase labels |

Native AppKit companions, when needed for application chrome, should resolve the corresponding system font rather than read editor preferences. No blanket font override is added at root. Symbol optical adjustments can remain local when their purpose is documented.

| `NoemaSpacing` property | Points | Purpose and first consumer |
| --- | ---: | --- |
| `xs` | 4 | Tight tab/icon grouping |
| `sm` | 8 | Navigation/custom row gaps and inner padding |
| `md` | 12 | Shared header gaps and compact panel rhythm |
| `lg` | 16 | Inspector/content inset and library heading alignment |
| `xl` | 20 | Larger grouped container separation, macro/settings modal |
| `xxl` | 24 | Sheet/group padding reference |
| `xxxl` | 32 | Empty/locked-state outer breathing room |

Zero spacing, native default padding and small 1–3 point optical corrections are valid exceptions. A component's current 6 or 10 point inset need not mechanically round to 8 or 12; choose by role and verify the result.

### Geometry API

`DesignTokens.swift` exposes `NoemaMetrics` static `CGFloat` properties. These are reference defaults for custom chrome, not native control overrides.

| Property | Points | Purpose and first consumer |
| --- | ---: | --- |
| `compactRowHeight` | 30 | Custom sidebar row minimum; current 28pt rows |
| `comfortableRowHeight` | 34 | Vault menu/comfortable custom navigation |
| `searchHeight` | 30 | Custom sidebar search; current 26pt |
| `sidebarInset` | 12 | Shared sidebar horizontal framing |
| `inspectorInset` | 16 | Inspector shell, header and panel horizontal alignment |
| `radiusSmall` | 6 | Custom selected tabs and compact controls |
| `radiusStandard` | 8 | Search and grouped custom control containers |
| `radiusLarge` | 12 | Larger custom containers, only where a real consumer exists |
| `borderWidth` | 0.5 | Custom group/search hairline; increased contrast may strengthen |
| `focusRingWidth` | 2 | Visible keyboard-focus and selected-press outlines on custom controls |
| `controlGroupInset` | 3 | Optical inset around tab groups |
| `iconWidth` | 16 | Shared chrome icon column |
| `toolbarControlHeight` | 28 | Custom compact action target reference |
| `readingMeasure` | 680 | Future reading-container reference in the 600–760pt range; not a block editor migration |

Prefer minimum heights and content-driven width for text-bearing custom controls. Do not clip essential actions to enforce a metric. Preserve current pane constraints and window minimum until visual validation establishes a justified change. `readingMeasure` may be deferred if it has no migrated consumer; it must not replace the editor's existing 980pt container and 80/85pt gutter alignment in this series.

## Integrated implementation

The shared chrome implements the contract in `Theme.swift`, `DesignTokens.swift` and `ChromeInteractionStyle.swift`, with consumers in `ContentView.swift` and the inspector views. The AppKit `nativeText(for:on:active:)` companion resolves the same actual-surface foreground as the SwiftUI API.

Custom controls use `NoemaChromeButtonStyle` and state-aware leaf foregrounds. Selection persists through hover, press and inactive-window states; pressing a selected control adds an outline. Focus adds a separate native-colored ring. Native controls retain their own state drawing. The sidebar List no longer animates as a whole, and retained local transitions respect Reduce Motion.

Custom icon actions have at least 28-point widths and navigation targets use minimum heights. The wider action targets can truncate long sidebar titles sooner at the minimum pane width; the page button exposes the full title through its accessibility text and tooltip.

`radiusLarge` remains a reference for future larger custom containers; it is not applied to native container shapes. Reading measure and a density preference remain deferred. Reproducible visual checks and unresolved live accessibility acceptance are recorded in [validation](../validation.md#design-token-acceptance).

## Deliberate component exceptions

### Native and component-specific approved exceptions

1. **Native controls and selection.** `SourcesLibraryView.Table`, standard List selection, table column minimum/ideal widths, native Form, Toggle, Slider, Menu, Picker, progress spinner, text editor, alert and sheet roles keep platform sizing and state drawing. Theme does not globally recolor labels inside native selected/prominent controls.
2. **Sidebar material and system appearance.** `SidebarMaterialView` uses a native visual-effect sidebar material for System/accent-only themes. A surface role identifies the purpose without replacing vibrancy. Menu material and source Quick Look retain native rendering.
3. **Editorial font and layout.** `EditorTypography` owns default15pt and allowed10–32pt font settings. `NativeTextViews` insets28×24, source reader24×24, rich editor80×24, block indentation24, block/text decoration geometry and semantic heading space remain component-owned. AppKit text selection uses `selectedTextColor` and `selectedTextBackgroundColor`.
4. **Brand identity.** `NoemaBrandPalette` RGB values, `NoemaMark` proportional tile radius/inset, Orbit geometry, app icon and About branding stay separate from interface palette. Existing palette RGB values in `MidnightIrisPalette` are data, not hard-coded view colors.
5. **Window/pane/layout constraints.** Main window960×620 minimum; sidebar250/265/280 range; Sources workspace520 minimum versus420; inspector280/340/420 range; sheet-specific dimensions and reading980/80/85 geometry remain semantic component constraints. Tokens may reference them later without changing behavior in this series.
6. **Optical geometry.** 0.5pt List insets, 1/1.5/2/3pt badge/control alignment, capsule shape, SF Symbol optical adjustments, native hairlines and zero-sized lifetime/state bridge views are intentional. `Color.clear` represents absence, not a missing theme role.
7. **Specialized editor palette/settings.** Non-activating block-command panel240pt width, native button cells/menu material and custom TeX command input sizes are established editor behaviors outside shared chrome scope. They may consume primitives only after their behavior is verified.
8. **Status semantics.** Semantic category colors in `SemanticRegistry` and unread blue indicators retain status/category meaning. Text/accessibility labels accompany them; themes must not turn all categories into accent.

These exceptions allow continued literals at meaningful component boundaries. An exception is not permission to add another ordinary navigation font, generic radius or custom row selection opacity.

## Interaction contract for UI.TK06

| State | Custom shared chrome behavior | First consumers |
| --- | --- | --- |
| Normal | Scoped primary/secondary text on actual surface; native controls draw themselves | Search, sidebar rows, tabs |
| Hover | Semantic `hover` backing; never impersonates selected navigation | Plain custom navigation/button targets |
| Pressed | Semantic `pressed`, scoped to press duration; preserve native button action handling | Plain custom buttons |
| Selected | `selection` + matching `textOnSelection`; independent of hover and visibly retained inactive | Sidebar and inspector tabs/rows |
| Focused | Native focus where available; `focusRing` for custom plain targets without visible native focus | Sidebar search, tabs and lock action |
| Disabled | Use `.disabled(...)` and native control drawing; custom labels can use `disabledText`; never remove semantic action state | Busy lock/source actions |
| Loading | Native `ProgressView`, metadata text, existing state logic; no whole-container animation | Source generation/checking and header progress |
| Destructive | Native destructive button/alert roles; semantic `destructive` only for custom text/notice affordances | Trash, import failure notices |

Existing `SidebarEditingLockControl` already reveals itself for locked/hovered/pending/focused/VoiceOver states. Preserve those conditions and keyboard/context-menu alternatives. No new action may depend exclusively on pointer hover. Small state transitions must honor Reduce Motion; retain existing environment checks, avoid animating whole workspace/editor content on selection, and do not introduce motion preferences or new selection logic.

## Validation requirements

Visual acceptance must exercise Light/Dark at standard/increased contrast; System accent and Midnight Iris; Reduce Motion; minimum-size window; sidebar/editor/Sources/inspector; locked/empty/no-vault; keyboard-only and VoiceOver; native controls/alerts/sheets. Preserve other selectable palettes and accent-only/full-palette settings as regression coverage. Capture baseline and migrated components where possible; if baseline, VoiceOver or environment automation cannot be obtained, explicitly record the gap rather than declaring the matrix complete. Build success alone is insufficient visual acceptance.

Run the repository's existing build and test scripts and retain relevant regression coverage for inspector context/tab memory, Sources selection/customization, Trash navigation, theme modes, editor typography and session-driven content visibility. Meaningful new tests exercise semantic-role resolution/contrast and interaction invariants rather than merely restating literal constants. Do not modify storage/session/scanning/indexing/file format semantics to satisfy presentation tests.


## Native toolbar integration

The native toolbar retains SwiftUI/AppKit fonts, geometry, focus, hover, pressed and
disabled drawing with the scene's `NoemaTheme` tint. Do not apply custom row fonts,
hit-target frames or `NoemaChromeButtonStyle` to native toolbar controls. Shared
sidebar/search/footer and inspector content retain semantic typography, spacing,
colors and focus. Content stays below the native titlebar; sidebar top inset uses
`NoemaSpacing.md`, and welcome/locked text resolves against `.window`. Native glass
buttons retain their own foreground and sizing. Window/pane dimensions remain
component-owned rather than density tokens. Isolated hosted fixture preferences must
not modify real workspace defaults. See [validation](../validation.md#native-window-acceptance).
