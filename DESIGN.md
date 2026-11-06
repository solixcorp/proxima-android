# Proxima Android interface

## 1. Intent

Operate: connect a selected VPN profile and manage a Proxima account without obscuring connection state. Existing native Material 3 components are the visual authority.

## 2. Color

`lib/app/proxima_app.dart` owns color through `ColorScheme.fromSeed`, seed `0xFF35618B`, and light/dark brightness. The default follows the system; the theme selector in Settings also offers explicit light and dark modes, persisted with the existing Android settings. Components use scheme roles rather than independent colors. Cards use `surfaceContainerLow`; inputs use `surfaceContainerHighest` at the existing opacity. Errors use error/onError roles and explanatory text.

## 3. Type

Use the current Flutter platform font and ThemeData text styles. Titles use titleMedium/titleLarge as established by AppPage and neighboring screens. Account explanatory/result text follows the existing 17 logical pixel body and 15 logical pixel detail sizes. Long account names, email, server labels and Korean strings wrap; never constrain required data to one line.

## 4. Spacing and layout

Existing spacing scale: 4, 8, 12, 16, 20, 24 logical pixels. AppPage supplies 16-pixel page gutters and one bounded CustomScrollView. Cards have the existing 20-pixel radius; inputs have the existing 16-pixel radius. Do not introduce another decoration system.

The shell changes from NavigationBar to NavigationRail at 600 logical pixels. It owns persistent navigation; pages own content scrolling.

Layout: account page - three Material containers in reading order: plan/usage, account services, subscription profile; scroll owner: AppPage CustomScrollView; anti-patterns: accordions, independently scrolling containers, fixed-height long content and horizontal primary content.

The account-services container holds named navigation rows. Each opens its own native service page with a visible Back control. Plan/usage reuses the existing account overview, including login/import, with links to full plan and usage details. The subscription-profile container groups the selected local profile and connection state without source addresses or horizontal separators, including before login. No account accordion or expand/collapse affordance remains, including FAQ and announcements. Receipt, conversation and guide buttons open child detail pages rather than expanding inline. Plan/usage loads on entry; service and detail reads begin on navigation without automatically requesting permissions. Subscription-address/domain selection and link rotation remain omitted; import and backend/ownership policy are unchanged. Response-size changes retain the existing reduced-motion-aware transition.

Layout: account service and detail pages - native AppPage destinations with back navigation -> one vertical content stack; scroll owner: each page's AppPage CustomScrollView; anti-patterns: accordion disclosure, unscoped cached private data across account/session changes and additional vertically scrolling result containers.

Selectable email and guide text have nested text-selection scrollers for their own content; editors own a separate dialog scroller. Offscreen IndexedStack pages retain their own page scrollers and are not account-region siblings. FAQ, guide, announcement and support prose uses 17-pixel body text, starts at the leading edge and is bounded to 720 pixels on wide displays.

Layout: account editors - bounded native forms and confirmations -> AlertDialog; scroll owner: the dialog's SingleChildScrollView when fields exceed its height; nested EditableText scrollers belong to individual inputs; anti-patterns: another modal route for details, clipped actions, an unbounded form.

Layout: retained shell pages - HomeScreen, ProfilesScreen and SettingsScreen -> existing IndexedStack siblings; scroll owners: each page's existing AppPage CustomScrollView (plus its own text controls), retained offscreen while the account destination is selected; anti-patterns: treating those retained owners as visible account-region scrollers.

Layout: Settings theme selection - a Material ListTile in the first card, followed by the existing settings groups; scroll owner: AppPage CustomScrollView, with a temporary dropdown-menu scroller only while choosing a theme; anti-patterns: a second page scroller, clipping the selected value, or resetting navigation on theme changes. The primary task is choosing a theme; priorities are the current selection, the three available modes, then the existing network and tunnel settings. No account, profile, or VPN behavior is changed.

Layout: wide shell navigation - NavigationRail at widths of 600 logical pixels or more -> independent navigation region; scroll owner: the shell SingleChildScrollView wrapping NavigationRail, not a dialog or account content owner; anti-patterns: counting this rail as nested account scrolling.

## 5. Components and states

- AppPage: collapsing/pinned page title, optional refresh, single vertical scroller.
- SectionHeader: grouped task heading using existing typography and spacing.
- AppValueTile/ListTile: responsive labeled values; long values wrap.
- ProximaAccountCard: existing identity, plan/quota/expiry and subscription import overview; signed out, busy, error and success states.
- Service ListTiles and detail buttons: native page navigation, no expand/collapse state.
- Material form fields and buttons: named controls, validation, focus, busy/disabled states.
- Confirmation dialogs: only for consequential actions; visible Cancel and outcome verb, no destructive default focus.
- Account sections: unloaded/loading, empty, successful, permission-required and request-failure states; errors and retry stay beside the failed section.

Primary action is Proxima login when signed out and subscription import when signed in. Account information comes first, then management, then read-only payment records and help. No purchase catalogue, checkout, billing portal, promotion, payment-method or trial-changing controls.

## 6. Verification

Actual native captures at 390 and 1440 logical pixels, system light/dark, every section and scroll end, plus signed-out/empty/error/permission and large-text states. Preserve neighboring subscription/profile/navigation behavior. A fixture run proves UI rendering and local interactions, not actual OAuth or provider data.
