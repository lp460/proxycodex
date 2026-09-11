# ProxyCodex release setup

The repository contains two automated delivery workflows:

- `pages.yml` publishes `docs/` to GitHub Pages.
- `release.yml` builds, signs and notarizes a universal macOS DMG, generates a
  signed Sparkle appcast, and attaches both files to a GitHub Release.

## One-time GitHub Pages setup

In **Settings → Pages → Build and deployment**, select **GitHub Actions**.
The public site will be available at `https://lp460.github.io/proxycodex/`.

## One-time signing setup

Add these values in **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE` | Developer ID Application `.p12`, base64 encoded |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `CI_KEYCHAIN_PASSWORD` | A new random password used only for the temporary CI keychain |
| `SPARKLE_PRIVATE_KEY` | Private EdDSA key produced by Sparkle `generate_keys` |
| `SPARKLE_PUBLIC_KEY` | Public EdDSA key printed by Sparkle `generate_keys` |

Never commit the private key or the `.p12` file. The public Sparkle key is
injected into the release app's `Info.plist`; the private key is used only by
the release workflow to sign the update feed.

## Publish a version

Create and push a semantic version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow then publishes:

- `ProxyCodex.dmg`
- `appcast.xml`

The website resolves the current DMG from the GitHub Releases API. Installed
copies use the stable Sparkle feed URL
`https://github.com/lp460/proxycodex/releases/latest/download/appcast.xml`, so
neither the website nor the application needs to be edited for later releases.
