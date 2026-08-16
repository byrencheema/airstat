# Releasing AirStats

Every shipped copy of AirStats asks `https://airstats.app/appcast.xml` once a day
whether a newer version exists, and installs what it finds there. That makes the order
below load-bearing: the appcast is published last, because it is the only step that
tells anyone to go and download anything.

## 1. Bump the version

`Resources/Info.plist`, both keys:

- `CFBundleShortVersionString` is what people read, e.g. `1.2`.
- `CFBundleVersion` is what Sparkle compares, and it must go **up** every release:
  1.0 was `1`, 1.1 is `2`, 1.2 is `3`. A release that bumps only the first ships an
  update nobody can install, because Sparkle refuses one that is not higher than the
  copy already running.

Commit that on its own.

## 2. Build the release

```sh
Scripts/release.sh
```

It builds, signs Sparkle's nested executables and then the app with the Developer ID
certificate, notarizes and staples both the app and the `.dmg`, signs the dmg with the
EdDSA key, writes the item into the site's `public/appcast.xml`, and prints everything
below. It leaves `dist/AirStats.dmg` and a copy under `dist/AirStats-<version>.dmg`.

Notarization takes minutes. It needs, all of which are already on this machine:

| What | Where |
| --- | --- |
| Developer ID Application certificate | login keychain (`SIGN_IDENTITY` overrides) |
| `notarytool` credential profile `AirStats` | login keychain (`NOTARY_PROFILE` overrides) |
| Sparkle's `sign_update` | `.build/artifacts/sparkle/Sparkle/bin` (`SPARKLE_BIN` overrides) |
| The EdDSA private key | `~/private_keys/airstats_sparkle_ed25519.key` (`SPARKLE_KEY` overrides) |

**Back that key up somewhere that is not this laptop.** It is what proves an update came
from us. Lose it and no copy in the field can ever be updated again; replace it and
every copy in the field is orphaned the same way, because they check the signature
against the `SUPublicEDKey` they shipped with.

## 3. Tag and publish the release

```sh
git tag v1.2 && git push origin v1.2
gh release create v1.2 dist/AirStats.dmg --title "AirStats 1.2"
```

The asset must be named exactly `AirStats.dmg`. Both the README's download link and the
appcast item point at `releases/download/v<version>/AirStats.dmg`, and the site's
download button resolves `releases/latest/download/AirStats.dmg`.

## 4. Bump the Homebrew cask

In `byrencheema/homebrew-tap`, `Casks/a/airstats.rb`: the `version` and the `sha256`
that `release.sh` printed. Commit and push. Homebrew installs are not reached by
Sparkle's notice in any useful way, so this is what upgrades them.

## 5. Push the appcast, last

In the site repo, `public/appcast.xml` now has the new item. Read it, commit that file
alone, push. Vercel deploys it, `Cache-Control` holds it for five minutes, and installed
copies start offering the update within a day.

Last for one reason: the item points at the GitHub asset from step 3. Publishing it
before that release exists points every AirStats on earth at a 404.

```sh
curl https://airstats.app/appcast.xml
```

## Testing an update without shipping one

Sparkle reads the feed from the `AirStatsFeedURL` user default when it is set, which
means a staging appcast on a preview host can be offered to a real installed copy:

```sh
defaults write com.airstat.AirStats AirStatsFeedURL https://<preview>/staging/appcast.xml
# ...
defaults delete com.airstat.AirStats AirStatsFeedURL
```

The feed has to be https, so a local server will not do: Sparkle refuses anything else
and so does App Transport Security.

It also has to be reachable without signing in, which rules out the obvious host. The
Vercel project protects every deployment except its custom domains, so a preview URL
answers Sparkle with a 302 to a Vercel login page rather than with the appcast. Staging
files have to go somewhere public: airstats.app itself under a path nothing links to,
or a host outside Vercel.
