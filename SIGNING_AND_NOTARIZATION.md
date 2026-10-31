# Signing and notarizing the M1005 macOS installer

The public installer must contain Developer ID signed app code, be signed with a Developer ID Installer certificate, and be notarized and stapled by Apple. An Apple Developer login alone does not provide the signing keys on a Mac.

## Prerequisites

1. Have an active Apple Developer Program membership and accept any outstanding agreements in [Apple Developer Account](https://developer.apple.com/account/) and, if applicable, [App Store Connect](https://appstoreconnect.apple.com/agreements/). The account holder must review and accept applicable terms.
2. In Keychain Access, install **Developer ID Application** and **Developer ID Installer** certificates together with their matching private keys. Apple's [certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) describe creating or importing them. Keep private keys private.
3. Install Xcode and its command-line tools; build dependencies are described in the README. Check identities in Terminal:

   ```sh
   security find-identity -v
   ```

   On this Mac the expected team is `75TH5B56SD`. Select the identities for the intended release team; the installer identity may not appear when filtering only for code-signing policy.
4. Configure a notarytool Keychain profile if one is not already available. For Apple Account authentication, first create an [app-specific password](https://support.apple.com/en-us/102654), then run the interactive command below and enter the requested credentials locally. Never put passwords in source files, chat, shell history, or release notes.

   ```sh
   xcrun notarytool store-credentials m1005-notary
   xcrun notarytool history --keychain-profile m1005-notary
   ```

   `notarytool store-credentials --help` describes API-key and other options. A 403 reporting a missing or expired agreement requires the relevant account holder to review the account agreements; retries alone do not fix it. Apple documents the workflow at [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Build, sign, notarize, and staple

From the project directory, set the identity names to those shown by `security find-identity -v`, then run:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Sarthak Gupta (75TH5B56SD)'
export DEVELOPER_ID_INSTALLER='Developer ID Installer: Sarthak Gupta (75TH5B56SD)'
export NOTARY_PROFILE='m1005-notary'
make phase5-release
```

Approve any macOS Keychain access prompts for the signing tools locally. The release script signs the two embedded executables and app with Developer ID Application and Hardened Runtime, builds and signs a non-relocatable `/Applications` installer with Developer ID Installer, submits the package using `notarytool`, waits for Apple, staples the ticket, and checks the installer with Gatekeeper. Its output is `build/release/HP-LaserJet-M1005-<version>.pkg`.

If notarization fails after the package is built, the file may be signed but is **not ready for public release**. Fix the reported problem and rerun `make phase5-release`. For an Apple rejection with a submission ID, retrieve the log using `xcrun notarytool log SUBMISSION_ID --keychain-profile m1005-notary`.

## Verify before publishing

```sh
pkgutil --check-signature build/release/HP-LaserJet-M1005-0.5.4.pkg
xcrun stapler validate build/release/HP-LaserJet-M1005-0.5.4.pkg
spctl --assess --type install --verbose=2 build/release/HP-LaserJet-M1005-0.5.4.pkg
shasum -a 256 build/release/HP-LaserJet-M1005-0.5.4.pkg
```

Replace the version in these example paths for future releases. Validate installation, the service, printing, Dock reopening, and uninstall on an appropriate clean Mac. Confirm the release tag points to the source used to build the package, including any local changes, and include the required source and license notices. Publishing should use the signed, notarized `.pkg`, not the `-unsigned.pkg` development artifact. Log in with `gh auth login` if GitHub CLI authentication is missing, then use GitHub's release interface or `gh release create` with the intended source tag and package.
