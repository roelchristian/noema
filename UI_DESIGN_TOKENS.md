# Noema design tokens and visual foundations

UI.TK01 contract · audited 12 October 2026 · integration branch `dev/ui-design-tokens`

This contract gives shared application chrome a single presentation vocabulary. `NoemaTheme` remains the only appearance resolver. Native SwiftUI and AppKit controls retain their interaction, accessibility, sizing and system appearance behavior. Document typography, branding geometry, storage, sessions and serialization are outside this migration.

The baseline inventory below records styling before UI.TK02–06; it is not a claim that every occurrence must be replaced. Migration uses semantic purpose, rather than numeric equality. UI.TK07 must record actual validation and remaining exceptions separately.

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

Add the following interface in `Theme.swift`, keeping existing `ThemeRole` methods available for document and brand consumers. The argument labels avoid ambiguous `.textPrimary` inference between the old and new role enums.

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

The baseline `PaletteSurfaceModifier` applies a global two-level foreground style. UI.TK02 must remove or limit that override to prevent nested native controls from inheriting palette foregrounds that mismatch native selected/prominent fills. Scoped text styling and root surface/tint resolution are allowed. Existing system color/accessibility notification invalidation stays in the theme modifier.

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

UI.TK04 extends `DesignTokens.swift` with `NoemaMetrics` static `CGFloat` properties. These are reference defaults for custom chrome, not native control overrides.

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
| `controlGroupInset` | 3 | Optical inset around tab groups |
| `iconWidth` | 16 | Shared chrome icon column |
| `toolbarControlHeight` | 28 | Custom compact action target reference |
| `readingMeasure` | 680 | Future reading-container reference in the 600–760pt range; not a block editor migration |

Prefer minimum heights and content-driven width for text-bearing custom controls. Do not clip essential actions to enforce a metric. Preserve current pane constraints and window minimum until visual validation establishes a justified change. `readingMeasure` may be deferred if it has no migrated consumer; it must not replace the editor's existing 980pt container and 80/85pt gutter alignment in this series.

## Baseline styling audit and migration map

### Repeated/competing treatments

| Area and locations | Baseline literals and treatment | Classification and migration |
| --- | --- | --- |
| Sidebar search, `ContentView.sidebar` | 12/12.5pt text, 11pt clear icon, 10pt shortcut; 26pt height, 7pt radius; primary 0.06 fill and 0.08 border | Reusable interface/metadata fonts, search/control metrics, elevated/separator/focus roles; UI.TK05–06 |
| Sidebar tab group and `InspectorTabBar` | Both 3pt outer padding, 8pt group radius, primary 0.05 fill, 0.07 border, 0.5pt stroke; sidebar selected 0.08/0.11 vs inspector 0.09/0.16 | Competing identical purpose; one semantic surface/selection/separator family, one geometry family |
| Sidebar page/item rows, `ContentView.sidebarPageRow/sidebarItemRow` | 13pt labels; 11pt dates; 7pt radius; 28pt height; primary 0.08 selected fill; 7pt internal gaps and 0.5pt row insets | Reusable navigation, metadata, compact row/selection tokens; retain tiny list optical insets |
| Sidebar footer and vault menu | Footer 12pt, 24pt target; vault callout/medium and caption2; 34pt minimum; 8pt inner padding | Typography/spacing/custom hit targets; native Menu internals remain native |
| Sidebar section labels | 11pt semibold uppercase | `sidebarSection`; preserve meaning, disclosure and collapse state |
| Sidebar footer divider | Increased-contrast opacity 0.75 vs 0.2 | Competes with custom group borders and inspector native divider; use structural separator role or native Divider without arbitrary suppression |
| Library headings, `ContentView.pageLibrary/pageLibraryContent/trashLibrary` | title2 bold, horizontal 16pt; top14/bottom10, 8pt stack and 12pt header gaps | `libraryTitle`, common insets/spacing; optical top/bottom remain deliberate if titlebar alignment requires |
| Page library cards | headline title, callout excerpt, caption tags/dates; horizontal12/vertical8 | Shared chrome typography/spacing; native List selection remains native |
| Sources library, `SourcesLibraryView` | Native Table columns; mini progress and 6pt status gap | Frame/header migration in ContentView; retain all Table internals, sorting, selection, widths and customization |
| Inspector shell | horizontal16/top12/bottom10; native Divider; existing theme background | `inspectorInset`, spacing and inspector/separator roles; preserve tab memory and scroll state |
| Inspector panels | Repeated horizontal16/vertical12; callout medium labels, caption and caption2 metadata; 16pt icon columns | Inspector inset, typography, spacing and icon metric across Links/References/Tags/Properties/Insights |
| Inspector header badges | 13pt semibold header; 11pt medium badge; 6×1.5pt capsule padding, primary 0.07 backing | Header/metadata fonts; semantic backing; capsule shape and 1.5pt optical inset retained |
| Document title/status chrome | 26pt semibold title; header85pt gutter/top14/bottom12, width980; footer28×14 padding and elevated backing | Title typography and status colors; preserve gutter/width editorial alignment and editor body |
| Locked and no-vault views | 46pt lock symbol; 32pt state title; welcome 38pt name and 116pt brand mark; widths460/560, 32pt outer padding | Empty-state typography/layout exceptions; named outer spacing optional; brand assets unchanged |
| Vault creation/settings | Native grouped Form and controls; sheet padding24/width540; folder card padding10/radius8; 245×24 palette picker | Shared radius/spacing only where appropriate; preserve native grouped Form/picker sizing and destructive/disabled behavior |
| Custom TeX macro settings | Tint0.12 badge; accent0.08 editing row; radius6; 6×2 badge insets, 4pt row padding; modal580 and list120–220 | Specialized settings editor outside shared chrome migration; record as deliberate exception pending separate polish |
| Notices/URL import | Red errors and native destructive action roles | New destructive role for custom error text; keep native `Button(role: .destructive)` and alert roles |
| Semantic blocks and unread indicators | System semantic category colors; fixed blue unread marker4pt / icon8pt | Category/unread status colors are meaningful component semantics, not ordinary accent; keep with accessible text/help |
| Theme palette picker | Native NSPopUpButton, dynamic swatches, separator0.5pt outline | Native picker + specialized palette preview; retain preview lifecycle and swatch geometry |

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

## Implementation sequence and validation handoff

| Task | Deliverable / files | Dependency and acceptance gate |
| --- | --- | --- |
| UI.TK01 | This inventory, ownership/API contract and exception map | Documentation only; no source refactoring |
| UI.TK02 | Semantic color enum/resolvers in Theme.swift; focused role/contrast tests | TK01; dynamic System colors, all existing palette modes, no global foreground breakage |
| UI.TK03 | Typography and spacing in DesignTokens.swift | TK01; preserve EditorTypography settings and macOS text-style behavior |
| UI.TK04 | Geometry metrics in DesignTokens.swift | TK03; custom targets readable, no density preference or native-control resize |
| UI.TK05 | ContentView shared chrome, inspector shell/panels and Sources framing | TK02–04; no Table internals/block layout/titlebar/brand changes; preserve all navigation/session gates |
| UI.TK06 | Shared custom interaction presentation | TK02–05; selected vs hover, inactive selection, focus and accessible hidden actions |
| UI.TK07 | Build/test results, visual evidence, accessibility matrix and retained-literal report | TK01–06; distinguish automated results, actual native inspection and pending checks |

UI.TK07 must exercise Light/Dark at standard/increased contrast; System accent and Midnight Iris; Reduce Motion; minimum-size window; sidebar/editor/Sources/inspector; locked/empty/no-vault; keyboard-only and VoiceOver; native controls/alerts/sheets. Preserve other selectable palettes and accent-only/full-palette settings as regression coverage. Capture baseline and migrated components where possible; if baseline, VoiceOver or environment automation cannot be obtained, explicitly record the gap rather than declaring the matrix complete. Build success alone is insufficient visual acceptance.

Run the repository's existing build and test scripts and retain relevant regression coverage for inspector context/tab memory, Sources selection/customization, Trash navigation, theme modes, editor typography and session-driven content visibility. Meaningful new tests exercise semantic-role resolution/contrast and interaction invariants rather than merely restating literal constants. Do not modify storage/session/scanning/indexing/file format semantics to satisfy presentation tests.

## Exhaustive literal index for audited view files

The following index was extracted from the pre-migration checkout. It preserves source line references and concrete values for color, opacity, font, spacing, geometry and animation calls. Repeated exact expressions within a file are grouped. It includes native and deliberate exceptions; classification follows the tables above. Lines shift during migration. Existing theme/palette data is covered above rather than repeated as view literals.

### `Sources/noema/ArticleTextView.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.font()` | 57, 72 |
| Color | `NSColor.separatorColor` | 111 |
| Color | `NSColor.secondaryLabelColor` | 129, 136 |
| Typography | `NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]) }` | 129 |
| Typography | `NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])` | 136 |
| Typography | `NSFont.systemFont(ofSize: 14, weight: .medium),` | 145 |
| Color | `NSColor.windowBackgroundColor` | 216 |
| Color | `NSColor.labelColor` | 217 |
| Typography | `NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])` | 217 |

### `Sources/noema/BlockCommands.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.systemFont(ofSize: 11, weight: .semibold)` | 163 |
| Typography | `.systemFont(ofSize: 14)` | 171 |
| Color | `NSColor.labelColor` | 172 |
| Typography | `NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])` | 172 |
| Geometry | `cornerRadius = 10` | 210 |

### `Sources/noema/BlockEditorCoordinator.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.frame(caret: screenRect, available: available, desired: palette.preferredContentSize)` | 183 |

### `Sources/noema/BlockTextStorage.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.font(weight: .semibold) }` | 16 |
| Typography | `.font(offset: sizes[block.kind] ?? 0, weight: sizes[block.kind] == nil ? .regular : .semibold),` | 41 |

### `Sources/noema/ContentView.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.frame(minWidth: 250, idealWidth: 265, maxWidth: 280, maxHeight: .infinity)` | 75 |
| Spacing/layout | `.frame(minWidth: model.scope == .sources && model.currentNote == nil && model.currentSource == nil ? 520 : 420, maxHeight: .infinity).transaction { $0.animation = nil }` | 76 |
| Typography | `.font(.title2.bold())` | 103, 729, 838, 944, 1258, 1275, 1296, 1338, 1365 |
| Typography | `.font(.caption).foregroundStyle(theme.text()) } }` | 106 |
| Spacing/layout | `.padding(28).frame(width: 440)` | 109 |
| Typography | `.font(.system(size: 46, weight: .medium))` | 173 |
| Typography | `.font(.system(size: 32, weight: .semibold))` | 178 |
| Typography | `.font(.callout)` | 180, 476, 790, 974, 1278 |
| Spacing/layout | `.frame(maxWidth: 460)` | 183 |
| Spacing/layout | `.frame(maxWidth: 560)` | 221, 252 |
| Spacing/layout | `.padding(32)` | 224 |
| Spacing/layout | `.frame(maxWidth: .infinity, maxHeight: .infinity)` | 225, 254, 941, 1028 |
| Spacing/layout | `.frame(width: 116, height: 116).accessibilityHidden(true)` | 232 |
| Typography | `.font(.system(size: 38, weight: .medium))` | 234 |
| Typography | `.font(.title3).foregroundStyle(theme.text())` | 236 |
| Typography | `.font(.callout).foregroundStyle(theme.text())` | 245 |
| Spacing/layout | `.frame(width: 20, height: 20).accessibilityHidden(true)` | 273 |
| Color | `.foregroundStyle(.primary)` | 274, 481, 562, 614, 670 |
| Typography | `.font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)` | 274 |
| Typography | `.font(.system(size: 12))` | 279, 665, 690, 1392 |
| Color | `.foregroundStyle(.secondary)` | 280, 290, 300, 371, 416, 427, 477, 486, 517, 569, 691, 909, 911, 912, 915, 945, 1165, 1339, 1366, 1423 |
| Typography | `.font(.system(size: 12.5))` | 285, 289 |
| Typography | `.font(.system(size: 11))` | 299, 568, 621, 1422 |
| Typography | `.font(.system(size: 10, weight: .medium))` | 303 |
| Color | `.foregroundStyle(.tertiary)` | 304, 622 |
| Spacing/layout | `.padding(.horizontal, 8)` | 307, 488 |
| Spacing/layout | `.frame(height: 26)` | 308 |
| Geometry | `RoundedRectangle(cornerRadius: 7, style: .continuous)` | 310, 314, 648, 679 |
| Opacity/state motion | `.opacity(0.06))` | 311 |
| Opacity/state motion | `.opacity(0.08), lineWidth: 0.5)` | 315 |
| Spacing/layout | `.padding(3)` | 347 |
| Geometry | `RoundedRectangle(cornerRadius: 8, style: .continuous)` | 349, 353 |
| Opacity/state motion | `.opacity(0.05))` | 350 |
| Opacity/state motion | `.opacity(0.07), lineWidth: 0.5)` | 354 |
| Opacity/state motion | `.animation(tabAnimation, value: activeSidebarTab)` | 356 |
| Spacing/layout | `.padding(.horizontal, 12)` | 359, 499 |
| Spacing/layout | `.padding(.top, 32)` | 360 |
| Spacing/layout | `.padding(.bottom, 6)` | 361 |
| Typography | `.font(.caption)` | 370, 773, 793, 841, 877, 885 |
| Typography | `.font(.system(size: 11, weight: .semibold))` | 415, 426 |
| Opacity/state motion | `.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: activeSidebarTab)` | 435 |
| Opacity/state motion | `.opacity(colorSchemeContrast == .increased ? 0.75 : 0.2)` | 438 |
| Spacing/layout | `.frame(width: 16)` | 478, 667 |
| Typography | `.font(.callout.weight(.medium))` | 480 |
| Typography | `.font(.caption2.weight(.medium))` | 485 |
| Spacing/layout | `.padding(.vertical, 8)` | 489, 1268 |
| Spacing/layout | `.frame(maxWidth: .infinity, minHeight: 34)` | 490 |
| Spacing/layout | `.padding(.top, 8)` | 500 |
| Spacing/layout | `.padding(.bottom, 10)` | 501, 744 |
| Typography | `.font(.system(size: 12.5, weight: showLabel ? .medium : .regular))` | 556 |
| Typography | `.font(.system(size: 12.5, weight: .medium))` | 561 |
| Spacing/layout | `.padding(.horizontal, showLabel ? 8 : 0)` | 577 |
| Spacing/layout | `.frame(maxWidth: showLabel ? .infinity : 30, minHeight: 26, maxHeight: 26)` | 578 |
| Geometry | `RoundedRectangle(cornerRadius: 6, style: .continuous)` | 583 |
| Opacity/state motion | `.opacity(highlighted ? 0.11 : 0.08))` | 584 |
| Typography | `.font(.system(size: 13, weight: .regular))` | 613, 669 |
| Spacing/layout | `.frame(maxWidth: .infinity, minHeight: 28)` | 629 |
| Spacing/layout | `.padding(.leading, 2)` | 643, 674, 692 |
| Spacing/layout | `.padding(.trailing, 4)` | 644 |
| Spacing/layout | `.frame(height: 28)` | 645, 676 |
| Opacity/state motion | `.opacity(0.08) : Color.clear)` | 649, 680 |
| Spacing/layout | `.listRowInsets(EdgeInsets(top: 0.5, leading: 0, bottom: 0.5, trailing: 4))` | 651, 684 |
| Spacing/layout | `.padding(.trailing, 8)` | 675, 693 |
| Spacing/layout | `.frame(height: 24, alignment: .leading)` | 694 |
| Spacing/layout | `.listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 4))` | 698 |
| Typography | `.font(.title2).padding()` | 712 |
| Spacing/layout | `.padding()` | 712 |
| Spacing/layout | `.padding(.horizontal, 16)` | 742 |
| Spacing/layout | `.padding(.top, 14)` | 743 |
| Spacing/layout | `.frame(maxHeight: .infinity)` | 757, 1038 |
| Typography | `.font(.system(size: 8))` | 765 |
| Color | `Color(nsColor: .systemBlue))` | 766 |
| Typography | `.font(.headline).lineLimit(1)` | 770 |
| Color | `.foregroundStyle(.secondary).lineLimit(1).fixedSize()` | 780 |
| Typography | `.font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()` | 780 |
| Spacing/layout | `.padding(.horizontal, 12).padding(.vertical, 8).tag(row.id)` | 796 |
| Color | `.foregroundStyle(.secondary).padding(12)` | 832, 938 |
| Typography | `.font(.caption).foregroundStyle(.secondary).padding(12)` | 832, 938 |
| Spacing/layout | `.padding(12)` | 832, 938 |
| Spacing/layout | `.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)` | 893, 951 |
| Typography | `.font(.headline)` | 908, 1049, 1054, 1262 |
| Typography | `.font(.caption).foregroundStyle(.secondary)` | 909, 911, 912, 945, 1165 |
| Typography | `.font(.callout).foregroundStyle(.secondary)` | 915, 1366 |
| Spacing/layout | `.padding(.vertical, 7)` | 924 |
| Spacing/layout | `.padding(12) }` | 939 |
| Opacity/state motion | `.opacity(0.12))` | 982, 989 |
| Spacing/layout | `.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12))` | 982 |
| Typography | `.font(.callout).padding(12).background(.orange.opacity(0.12))` | 989 |
| Spacing/layout | `.padding(12).background(.orange.opacity(0.12))` | 989 |
| Typography | `.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)` | 992 |
| Spacing/layout | `.padding(12).frame(maxWidth: .infinity, alignment: .leading)` | 992 |
| Typography | `.font(.caption).foregroundStyle(theme.text()).padding(8)` | 1006 |
| Spacing/layout | `.padding(8)` | 1006 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.plain)` | 1008 |
| Spacing/layout | `.padding(6).frame(width: 270).glassEffect(.regular, in: .rect(cornerRadius: 16)).padding(16)` | 1010 |
| Geometry | `cornerRadius: 16)).padding(16)` | 1010 |
| Spacing/layout | `.frame(maxWidth: model.currentNote != nil ? .infinity : 980).frame(maxWidth: .infinity)` | 1012 |
| Spacing/layout | `.frame(width: 76, height: 76).accessibilityHidden(true)` | 1023 |
| Typography | `.font(.title2.weight(.medium))` | 1024 |
| Spacing/layout | `.frame(maxWidth: 500) }` | 1027 |
| Spacing/layout | `.padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6) }` | 1029 |
| Color | `Color(nsColor: presentation?.accent ?? .secondaryLabelColor))` | 1050 |
| Spacing/layout | `.frame(width: 20)` | 1051 |
| Color | `.foregroundStyle(.secondary).lineLimit(1)` | 1056 |
| Typography | `.font(.caption).foregroundStyle(.secondary).lineLimit(1)` | 1056 |
| Spacing/layout | `.padding(.horizontal, 12).padding(.vertical, 8).tag(hit.id)` | 1058 |
| Spacing/layout | `.frame(minWidth: 160)` | 1116 |
| Typography | `.font(.caption) }` | 1156, 1302 |
| Typography | `.font(.caption.weight(.medium)).foregroundStyle(theme.text())` | 1161 |
| Typography | `.font(.caption).foregroundStyle(theme.text())` | 1168, 1211, 1234, 1241, 1243, 1245 |
| Typography | `.font(.caption).foregroundStyle(theme.text(.graphHighlight, on: .background)).buttonStyle(.bordered).tint(theme.color(.graphHighlight)).controlSize(.small) } }` | 1198 |
| Typography | `.font(.system(size: 26, weight: .semibold)).textSelection(.enabled)` | 1202 |
| Spacing/layout | `.padding(.horizontal, 85).padding(.top, 14).padding(.bottom, 12)` | 1216 |
| Spacing/layout | `.frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)` | 1217 |
| Typography | `.font(.system(size: 26, weight: .semibold))` | 1228 |
| Typography | `.font(.caption) } }` | 1236 |
| Spacing/layout | `.padding(.horizontal, 14).padding(.vertical, 8)` | 1250 |
| Spacing/layout | `.padding(.horizontal, 28).padding(.vertical, 14).background(theme.color(.surfaceElevated))` | 1254 |
| Typography | `.font(.caption).foregroundStyle(theme.text()).textSelection(.enabled)` | 1263 |
| Spacing/layout | `.padding(24).frame(width: 580, height: 480)` | 1271 |
| Spacing/layout | `.padding(24).frame(width: 580, height: 420)` | 1282 |
| Typography | `.font(.system(.body, design: .monospaced))` | 1300, 1340 |
| Spacing/layout | `.padding(24).frame(width: 660, height: 540)` | 1311 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 1322 |
| Color | `.foregroundStyle(.secondary).help("Dismiss message")` | 1325 |
| Color | `.foregroundStyle(.red).textSelection(.enabled) }.frame(maxHeight: 120)` | 1343 |
| Spacing/layout | `.frame(maxHeight: 120)` | 1343 |
| Color | `.foregroundStyle(.secondary) }` | 1348 |
| Spacing/layout | `.padding(24).frame(width: 600, height: 400).interactiveDismissDisabled(importing)` | 1354 |
| Spacing/layout | `.padding(24).frame(width: 460).interactiveDismissDisabled(model.generatingTopicPage)` | 1379 |
| Color | `Color(nsColor: .systemBlue)).frame(width: 4, height: 4)` | 1396 |
| Spacing/layout | `.frame(width: 4, height: 4)` | 1396 |
| Spacing/layout | `.frame(width: 16, height: 28)` | 1400 |
| Opacity/state motion | `.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: locked)` | 1425 |
| Opacity/state motion | `.opacity(locked \|\| visible \|\| pending \|\| focused \|\| voiceOver ? 1 : 0)` | 1426 |
| Spacing/layout | `.frame(width: 20, height: 28)` | 1427 |

### `Sources/noema/EditorSettings.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Color | `.foregroundStyle(.secondary)` | 63, 68, 80, 84, 94, 96, 98, 106, 113, 115, 149, 162, 177, 226, 251 |
| Typography | `.font(.caption).foregroundStyle(.secondary)` | 63, 98, 106, 115, 226, 251 |
| Typography | `.font(.callout).foregroundStyle(.secondary)` | 68, 84, 94, 96, 113 |
| Typography | `.font(.caption)` | 79, 176, 271 |
| Spacing/layout | `.frame(width: 245, height: 24)` | 103 |
| Spacing/layout | `.padding(16).frame(width: 540)` | 118 |
| Typography | `.font(.headline)` | 146 |
| Typography | `.font(.callout)` | 148, 161 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 163 |
| Spacing/layout | `.padding(.vertical, 12)` | 164 |
| Spacing/layout | `.padding(.horizontal, 8)` | 165 |
| Typography | `.font(.system(.body, design: .monospaced))` | 173, 230, 241, 255 |
| Typography | `.font(.caption2.weight(.semibold))` | 183 |
| Spacing/layout | `.padding(.horizontal, 6)` | 185, 210 |
| Spacing/layout | `.padding(.vertical, 2)` | 186 |
| Opacity/state motion | `.opacity(0.12), in: Capsule())` | 187 |
| Spacing/layout | `.padding(.vertical, 4)` | 209 |
| Geometry | `RoundedRectangle(cornerRadius: 6)` | 212 |
| Opacity/state motion | `.opacity(0.08) : Color.clear)` | 213 |
| Spacing/layout | `.padding(4)` | 217 |
| Spacing/layout | `.frame(minHeight: 120, maxHeight: 220)` | 219 |
| Spacing/layout | `.frame(width: 110)` | 231 |
| Spacing/layout | `.frame(width: 95)` | 238 |
| Color | `.foregroundStyle(.red)` | 272 |
| Spacing/layout | `.padding(6)` | 275 |
| Spacing/layout | `.padding(20)` | 278 |
| Spacing/layout | `.frame(width: 580)` | 279 |

### `Sources/noema/EditorTypography.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.font(withFamily: family, traits: [], weight: 5, size: pointSize) else {` | 26 |
| Typography | `.systemFont(ofSize: pointSize, weight: weight)` | 27 |

### `Sources/noema/Inspector/InsightsPanel.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.font(.caption)` | 110, 123, 199 |
| Color | `.foregroundStyle(.secondary)` | 111, 117, 124, 127, 157, 193, 200, 203 |
| Spacing/layout | `.padding(.horizontal, 16)` | 170, 218 |
| Spacing/layout | `.padding(.vertical, 12)` | 171, 219 |

### `Sources/noema/Inspector/InspectorContainer.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.padding(.horizontal, 16)` | 25 |
| Spacing/layout | `.padding(.top, 12)` | 26 |
| Spacing/layout | `.padding(.bottom, 10)` | 27 |
| Spacing/layout | `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` | 30 |
| Spacing/layout | `.frame(maxHeight: .infinity)` | 32 |
| Color | `.foregroundStyle(.primary)` | 131, 171, 274 |
| Color | `.foregroundStyle(.secondary)` | 133, 175, 242, 277, 282 |
| Typography | `.font(.caption)` | 135, 174, 181, 206, 241, 276 |
| Typography | `.font(.callout.weight(.semibold))` | 170 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 187, 203, 280 |
| Typography | `.font(.callout)` | 188, 201 |
| Color | `Color(nsColor: presentation?.accent ?? .secondaryLabelColor))` | 268 |
| Spacing/layout | `.frame(width: 20)` | 269 |
| Typography | `.font(.callout.weight(.medium))` | 273 |
| Typography | `.font(.body)` | 285 |

### `Sources/noema/Inspector/InspectorTabBar.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.font(.system(size: 13, weight: isSelected ? .semibold : .regular))` | 23 |
| Spacing/layout | `.frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)` | 25 |
| Geometry | `RoundedRectangle(cornerRadius: 6, style: .continuous)` | 29 |
| Opacity/state motion | `.opacity(colorSchemeContrast == .increased ? 0.16 : 0.09))` | 30 |
| Spacing/layout | `.padding(3)` | 42 |
| Geometry | `RoundedRectangle(cornerRadius: 8, style: .continuous)` | 44, 48 |
| Opacity/state motion | `.opacity(0.05))` | 45 |
| Opacity/state motion | `.opacity(colorSchemeContrast == .increased ? 0.25 : 0.07), lineWidth: 0.5)` | 49 |
| Opacity/state motion | `.animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selectedTab)` | 51 |
| Typography | `.font(.system(size: 13, weight: .semibold))` | 92 |
| Color | `.foregroundStyle(.primary)` | 93 |
| Typography | `.font(.system(size: 11, weight: .medium))` | 96 |
| Color | `.foregroundStyle(.secondary)` | 97 |
| Spacing/layout | `.padding(.horizontal, 6)` | 99 |
| Spacing/layout | `.padding(.vertical, 1.5)` | 100 |
| Opacity/state motion | `.opacity(0.07))` | 103 |
| Typography | `.font(.caption)` | 109 |
| Spacing/layout | `.padding(.horizontal, 16)` | 111 |
| Spacing/layout | `.padding(.vertical, 10)` | 112 |

### `Sources/noema/Inspector/LinksPanel.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Color | `.foregroundStyle(.secondary)` | 104, 107, 122, 125, 150, 161, 168, 189, 200, 207, 237, 243, 256, 262, 266 |
| Typography | `.font(.caption)` | 106, 124, 149, 167, 188, 206, 226, 242, 255 |
| Spacing/layout | `.padding(.horizontal, 16)` | 134 |
| Spacing/layout | `.padding(.vertical, 12)` | 135 |
| Spacing/layout | `.frame(width: 16)` | 151, 190, 228, 257 |
| Typography | `.font(.callout.weight(.medium))` | 155, 194, 232 |
| Color | `.foregroundStyle(.primary)` | 156, 195, 233 |
| Typography | `.font(.caption2)` | 160, 199, 236, 265 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 165, 204, 240, 269 |
| Spacing/layout | `.padding(.vertical, 3)` | 171, 210, 245, 278 |
| Typography | `.font(.callout)` | 261 |

### `Sources/noema/Inspector/PropertiesPanel.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Color | `.foregroundStyle(.primary)` | 39, 201 |
| Typography | `.font(.caption)` | 44, 72, 113, 133, 174, 193, 212, 231 |
| Spacing/layout | `.padding(.horizontal, 16)` | 80, 138 |
| Spacing/layout | `.padding(.vertical, 12)` | 81, 139 |
| Color | `.foregroundStyle(.secondary)` | 149, 154, 191, 229 |

### `Sources/noema/Inspector/ReferencesPanel.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Color | `.foregroundStyle(.secondary)` | 172, 175, 247, 252, 255 |
| Typography | `.font(.caption)` | 174, 246, 254 |
| Spacing/layout | `.padding(.horizontal, 16)` | 192, 272 |
| Spacing/layout | `.padding(.vertical, 12)` | 193, 273 |

### `Sources/noema/Inspector/TagsPanel.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Color | `.foregroundStyle(.secondary)` | 67, 70, 96, 138, 145, 148, 170 |
| Typography | `.font(.caption)` | 69, 113, 122, 131, 134, 137, 147, 157 |
| Typography | `.font(.caption.weight(.medium))` | 79 |
| Spacing/layout | `.padding(.top, 2)` | 125 |
| Typography | `.font(.caption2)` | 169 |
| Spacing/layout | `.padding(.horizontal, 16)` | 178 |
| Spacing/layout | `.padding(.vertical, 12)` | 179 |

### `Sources/noema/NativeTextViews.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Geometry | `textContainerInset = NSSize(width: 28, height: 24)` | 22, 108 |
| Color | `NSColor.selectedTextColor` | 38, 122 |
| Color | `NSColor.selectedTextBackgroundColor` | 39, 123 |
| Typography | `NSFont.systemFont(ofSize: size, weight: span.bold ? .semibold : weight)` | 143 |

### `Sources/noema/NoemaAbout.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.frame(width: 64, height: 64)` | 30 |
| Typography | `.font(.largeTitle.bold())` | 33 |
| Typography | `.font(.caption)` | 37, 56 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 46, 52 |
| Typography | `.font(.body)` | 50 |
| Spacing/layout | `.padding(28)` | 60 |

### `Sources/noema/NoemaApp.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.frame(minWidth: 960, minHeight: 620)` | 12 |
| Spacing/layout | `.frame(width: 660, height: 560)` | 75 |

### `Sources/noema/NoemaMark.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.padding(side * 10 / 116)` | 31 |
| Spacing/layout | `.frame(width: side, height: side)` | 32 |
| Geometry | `RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)` | 34 |
| Spacing/layout | `.frame(maxWidth: .infinity, maxHeight: .infinity)` | 37 |
| Color | `Color(.orbit))` | 51 |
| Color | `Color(.satellites))` | 52 |
| Color | `Color(.nucleus))` | 53 |
| Color | `Color(_ role: NoemaBrandRole) -> Color {` | 57 |
| Color | `Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)` | 65 |

### `Sources/noema/RichArticleView.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Geometry | `textContainerInset = NSSize(width: 80, height: 24)` | 28 |
| Color | `.foregroundStyle(.secondary).lineLimit(1)` | 101 |
| Typography | `.font(.callout).foregroundStyle(.secondary).lineLimit(1)` | 101 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .center)` | 103 |
| Spacing/layout | `.padding(.horizontal, 80).padding(.vertical, 8)` | 104 |
| Spacing/layout | `.frame(maxWidth: 980).frame(maxWidth: .infinity)` | 105, 150 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 114 |
| Color | `.foregroundStyle(.secondary)` | 118, 129 |
| Typography | `.font(.caption).foregroundStyle(.secondary)` | 118, 129 |
| Typography | `.font(.headline)` | 123 |
| Typography | `.font(.caption)` | 125, 133 |
| Spacing/layout | `.padding(.horizontal, 80).padding(.vertical, disclosure.collapsed ? 16 : 24)` | 140 |
| Spacing/layout | `.frame(maxWidth: 980, alignment: .leading)` | 141 |
| Spacing/layout | `.frame(maxWidth: .infinity)` | 142, 145 |
| Opacity/state motion | `.scaleEffect(y: 0.5).frame(height: 0.5)` | 147 |
| Spacing/layout | `.frame(height: 0.5)` | 147 |
| Opacity/state motion | `.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: disclosure.collapsed)` | 152 |
| Typography | `.font(.caption).fixedSize()` | 158 |

### `Sources/noema/SourceReader.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Geometry | `textContainerInset = NSSize(width: 24, height: 24)` | 82 |
| Typography | `.systemFont(ofSize: 14)` | 83 |

### `Sources/noema/SourcesLibraryView.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Spacing/layout | `.frame(width: 0, height: 0).accessibilityHidden(true)` | 35, 60 |
| Geometry | `.width(min: 160, ideal: 220)` | 83 |
| Geometry | `.width(min: 100, ideal: 150)` | 88 |
| Geometry | `.width(min: 85, ideal: 95)` | 94 |
| Geometry | `.width(min: 150, ideal: 180)` | 99 |
| Geometry | `.width(min: 80, ideal: 90)` | 103 |
| Geometry | `.width(min: 70, ideal: 90)` | 108 |
| Geometry | `.width(min: 100, ideal: 120)` | 116 |
| Color | `.foregroundStyle(.secondary)` | 165 |

### `Sources/noema/ThemePalettePicker.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Color | `NSColor.separatorColor` | 72 |
| Geometry | `lineWidth = 0.5` | 72 |

### `Sources/noema/VaultCreationSheet.swift`

| Category | Baseline expression | Lines |
| --- | --- | --- |
| Typography | `.font(.title2.bold())` | 21 |
| Typography | `.font(.subheadline.weight(.semibold))` | 27, 39, 71 |
| Typography | `.font(.callout).foregroundStyle(secondaryText)` | 34, 58, 63, 73, 80 |
| Spacing/layout | `.frame(maxWidth: .infinity, alignment: .leading)` | 45 |
| Spacing/layout | `.padding(10)` | 54 |
| Geometry | `RoundedRectangle(cornerRadius: 8))` | 55 |
| Typography | `.font(.callout).textSelection(.enabled)` | 85 |
| Typography | `.font(.callout) }` | 90 |
| Spacing/layout | `.padding(24).frame(width: 540)` | 99 |
