# iPad Landscape Support Design

## Goal

Allow Conduit to rotate between portrait and landscape on iPad while keeping
iPhone portrait-only. This is an orientation declaration change, not a
landscape-specific redesign of the chat UI.

## Current behavior

The app currently declares `UIInterfaceOrientationPortrait` in the universal
`UISupportedInterfaceOrientations` key. There is no iPad-specific override, so
iPad inherits the portrait-only restriction.

## Chosen approach

Use idiom-specific keys in the app's explicit `Conduit/Info.plist`:

- Keep `UISupportedInterfaceOrientations` as portrait-only. iPhone continues to
  accept only portrait.
- Add `UISupportedInterfaceOrientations~ipad` containing portrait,
  landscape-left, and landscape-right. iPad then rotates automatically between
  all three orientations.

This keeps platform policy declarative, avoids runtime orientation APIs, and
does not introduce device checks or orientation state into SwiftUI views.
`UIRequiresFullScreen` remains unchanged because multitasking behavior is
outside this request.

## Alternatives considered

1. Runtime orientation selection in the app delegate. Rejected: more code and
   lifecycle timing risk for a static platform policy.
2. Xcode build-setting-only configuration. Rejected: less explicit than the
   existing checked-in plist and harder to test as the shipped bundle
   contract.

## Testing and acceptance criteria

- Add a bundle-level regression test that verifies the base orientation array
  contains only portrait.
- Verify the iPad-specific array contains portrait, landscape-left, and
  landscape-right.
- Regenerate the Xcode project and run the complete iOS simulator test suite.
- Confirm the generated app plist preserves the two orientation arrays.
- No production SwiftUI view or iPhone behavior changes are required.

