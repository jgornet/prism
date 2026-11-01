# Open Health Sync for Swift, vendored

This folder is `sdks/swift` of https://github.com/soma-intelligence/open-health-sync at commit `df340135867064da1960f98f88da0efeef1c2739` (Release v0.3.0), copied without a change, with the repository's `LICENSE` (AGPL-3.0-only, as Prism).

The health server of this build runs Open Health Sync from the same commit, so the upload format of the app and of the server match. Swift Package Manager reads a package only at the root of a git repository, and this one is in a subfolder, so the app takes it as a local package (`../Packages/OpenHealthSync` in `App/Prism.xcodeproj`), as it takes SomaUI and WellnessKit.

To move to another commit, the same commit as `OHS_COMMIT` in `deploy/ohs/upstream.env` of `jgornet/health-mcp`:

```sh
rm -rf Packages/OpenHealthSync/Package.swift Packages/OpenHealthSync/Sources Packages/OpenHealthSync/Tests Packages/OpenHealthSync/README.md
git -C path/to/open-health-sync archive <commit> sdks/swift | tar -x --strip-components=2 -C Packages/OpenHealthSync
```

Then change the commit on this page.
