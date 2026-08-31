# Releasing QuotaWise for macOS

This repository contains source code, not a committed application bundle. A
public release is a signed, notarized ZIP uploaded as a GitHub Release asset.
The Homebrew Cask then points at that immutable ZIP.

## Prerequisites

The release Mac needs the private key for a valid Developer ID Application
certificate in its login Keychain. Confirm it without exporting the key:

```sh
security find-identity -v -p codesigning
```

Set the identity for the release command. The version must equal the
`CFBundleShortVersionString` in `Support/AppBundle/Info.plist`.

```sh
export QUOTAWISE_VERSION="1.1.1"
export QUOTAWISE_CODE_SIGN_IDENTITY="Developer ID Application: Jake Mawson (6RWK4446NQ)"
```

Never commit or upload the certificate's private key.

## Package and sign

Run the release workflow without `--notarize` to build the app, make a clean
copy at `build/release/<version>/QuotaWise.app`, sign every embedded executable
inside-out with hardened runtime and a secure timestamp, verify the signature,
and create the archive for Apple:

```sh
Scripts/release-macos
```

The script will not overwrite an existing `build/release/<version>` directory.
This keeps an already-generated release artifact from being replaced by mistake.

The pre-notarization artifact is:

```text
build/release/<version>/QuotaWise-<version>-notarization.zip
```

## Configure notarization once

Create an Apple app-specific password in the Apple Account website, then store
it locally in a Keychain profile. Enter the password only in the interactive
Apple tool, never in this repository or shell history.

```sh
xcrun notarytool store-credentials "quotawise-notary"
```

The prompt asks for the Apple ID, Team ID, and app-specific password. The Team
ID is visible in `codesign -dv --verbose=4` output as `TeamIdentifier`.

## Notarize, staple, and verify

With the profile already stored, submit the already-created and verified
versioned artifact without rebuilding or replacing it:

```sh
QUOTAWISE_VERSION="1.1.1" \
QUOTAWISE_CODE_SIGN_IDENTITY="Developer ID Application: Jake Mawson (6RWK4446NQ)" \
Scripts/release-macos --notarize-existing
```

The script submits the pre-notarization ZIP and waits for Apple's result. It
only staples when Apple returns `Accepted`; otherwise it leaves the submitted
archive available for `xcrun notarytool log <submission-id>`. On success it
validates the staple, runs Gatekeeper assessment, and creates the release asset:

```text
build/release/<version>/QuotaWise-<version>.zip
```

The final ZIP is created after stapling. Its SHA-256 is printed by the script;
it is the value required by Homebrew.

## Publish and distribute

Upload only the final ZIP to the matching GitHub Release tag, for example
`v1.1.1` on `JakeMawson/quotawise`. Do not commit `QuotaWise.app` to `main`.

For the immediate install route, put the following completed cask into the
separate `JakeMawson/homebrew-tap` repository at `Casks/quotawise.rb`:

```ruby
cask "quotawise" do
  version "1.1.1"
  sha256 "<SHA-256 OF QuotaWise-1.1.1.zip>"

  url "https://github.com/JakeMawson/quotawise/releases/download/v#{version}/QuotaWise-#{version}.zip"
  name "QuotaWise"
  desc "Local AI usage intelligence for macOS"
  homepage "https://github.com/JakeMawson/quotawise"

  depends_on macos: ">= :sequoia"

  app "QuotaWise.app"
end
```

After publishing the tap, validate the actual user path on a clean install:

```sh
brew install JakeMawson/tap/quotawise
open -a QuotaWise
```

The official `brew install quotawise` route needs a separate accepted pull
request to `Homebrew/homebrew-cask`; do not assume a personal tap makes the
cask globally available.
