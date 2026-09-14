# Releasing (iOS / SwiftPM)

Swift Package Manager distributes packages **by git tag** — there is no registry
upload step. To cut a release, tag a commit with a SemVer version and push it:

```bash
git tag 0.1.0
git push origin 0.1.0
```

Consumers then depend on the tag:

```swift
.package(url: "https://github.com/Cookie-Munch/ios.git", from: "0.1.0")
```

## Checklist

- CI (`swift build && swift test`) is green on `main`.
- The tag is an annotated, immutable SemVer tag (`MAJOR.MINOR.PATCH`); never move a
  published tag.
- (Optional) create a matching GitHub Release from the tag for changelog notes.

## No tokens required

SwiftPM resolves straight from the public git repo, so **no registry credentials or
release secrets are needed**. Publishing = pushing a tag.
