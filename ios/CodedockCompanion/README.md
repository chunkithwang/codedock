# codedock Buddy

This is the Xcode project for the codedock iPhone, Live Activity, and Apple Watch Buddy.

For the product overview, setup guide, protocol notes, and screenshots, see:

- [`../../apple-companion/README.md`](../../apple-companion/README.md)

## Project Contents

- `CodedockCompanion/` - iPhone app
- `CodedockCompanionWidget/` - iPhone Live Activity, Dynamic Island, and StandBy UI
- `CodedockWatchApp/` - Apple Watch app
- `CodedockWatchWidget/` - watchOS widget
- `Shared/` - shared models, display helpers, and mascot views
- `project.yml` - XcodeGen project definition

## Open in Xcode

```bash
cd ios/CodedockCompanion
xcodegen generate
open CodedockCompanion.xcodeproj
```
