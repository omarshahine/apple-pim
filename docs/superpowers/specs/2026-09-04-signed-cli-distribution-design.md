# Signed CLI Distribution — Design

Date: 2026-09-04
Status: proposed
Branch: `omarshahine/code-signing`

## Problem

macOS TCC grants for Calendar, Reminders, and Contacts are dropped on every
upgrade of the Apple PIM CLIs. Users re-answer the permission dialogs after
every `swift build`, every `./setup.sh --install`, and every `brew upgrade`.

The cause is ad-hoc code signing, and it is measurable rather than theoretical.

### Evidence

TCC records a client's **designated requirement** verbatim in `TCC.db`. On the
development machine, the stored requirement for the granted Calendar client
decodes to:

```
$ csreq -r req.bin -t
cdhash H"2f67bf86387f6ba74b5935050b7aa95ba6aebeba"
```

That is byte-for-byte the designated requirement of the installed binary:

```
$ codesign -d -r- ~/.local/bin/calendar-cli
# designated => cdhash H"2f67bf86387f6ba74b5935050b7aa95ba6aebeba"

$ codesign -dvvv ~/.local/bin/calendar-cli | grep Signature
Signature=adhoc
```

An ad-hoc signature has no certificate to anchor to, so `codesign` synthesises a
designated requirement that pins the raw code directory hash. Any change to the
binary produces a new cdhash, which no longer satisfies the stored requirement,
and TCC treats the client as unknown.

Signing with a real certificate produces a content-independent requirement.
Verified by signing two **different** binaries under one identifier and cert:

```
calendar-cli-signed  CDHash=fe2debf749e4e1eb54e686f45c70de2d8173428f
calendar-cli-v2      CDHash=409871b39647c5d47426deda2ef8b6fad11da642

both => identifier "com.omarshahine.apple-pim.calendar-cli"
        and anchor apple generic
        and certificate leaf[...]
```

Identical requirements despite different content. This is the fix.

### Two secondary findings

**Grants are path-keyed.** Every relevant `TCC.db` row is `client_type=1`, an
absolute binary path, not a bundle identifier. The same binary installed at two
paths holds two independent grants. This is already visible in the wild:
`~/.local/bin/contacts-cli` (`df3a5f54…`) and
`swift/.build/…/release/contacts-cli` (`cf34eaf…`) each hold their own
Contacts grant.

**`PIMHelper.app` is not the mechanism at fault.** It has no `TCC.db` entry for
any service, because `lib/cli-runner.js` only routes through it when the direct
probe returns `notDetermined`/`denied`. On a machine with working direct grants
it never engages. It is already signed `Developer ID Application: OmarKnows LLC
(N9DRSTM2U6)`. It is folded into this work for consistency, not because it is
currently broken.

## Goals

- A TCC grant, once given on a machine, survives every subsequent upgrade of the
  CLIs through every install path: `setup.sh`, Homebrew, npm, ClawHub.
- Grants survive Developer ID certificate renewal.
- Users who already granted permission re-approve exactly once, and are told why.
- An unverified or wrong-team binary is never installed.

## Non-goals

- Making grants transfer **between** machines. `TCC.db` is per-machine and does
  not sync. Each machine still prompts once, ever.
- Eliminating the one-time re-prompt caused by this migration. It is unavoidable:
  both the designated requirement and, for Homebrew users, the install path
  change.
- Signing anything not shipped by this repo.

## Design

### 1. Permanent code identities

Each CLI gets an explicit signing identifier:

| Binary         | Identifier                                |
|----------------|-------------------------------------------|
| `calendar-cli` | `com.omarshahine.apple-pim.calendar-cli`  |
| `reminder-cli` | `com.omarshahine.apple-pim.reminder-cli`  |
| `contacts-cli` | `com.omarshahine.apple-pim.contacts-cli`  |
| `mail-cli`     | `com.omarshahine.apple-pim.mail-cli`      |
| helper bundle  | `com.omarshahine.apple-pim.helper`        |

These are load-bearing forever. Changing one is exactly equivalent to revoking
every user's grant for that domain. They live in one file,
`scripts/lib/signing-identities.sh`, sourced by both the signing job and the
installer's verifier, so the two can never disagree.

The team identifier `N9DRSTM2U6` is equally permanent, for the same reason.

Developer ID designated requirements pin `certificate leaf[subject.OU]` — the
Team ID — not the certificate common name. Team OU is stable across certificate
renewal, so grants survive cert expiry and re-issue. (An `Apple Development`
cert pins `subject.CN` and would not; Developer ID is required, not merely
preferred.)

### 2. CI signing job

New workflow `.github/workflows/release-signed-artifacts.yml`, `macos` runner,
triggered on `v*` tags. Gated behind the same SDK contract preflight the other
three publish workflows use, so a premature tag cannot produce a partial release.

Steps:

1. Build `arm64` and `x86_64` slices, `lipo -create` into universal binaries.
   Today's build is single-architecture; a prebuilt artifact must serve both.
2. Import the Developer ID cert into a throwaway keychain from
   `APPLE_DEVELOPER_ID_P12_BASE64` / `APPLE_DEVELOPER_ID_P12_PASSWORD`. The
   keychain is deleted in an `always()` step so a failed run leaves no identity
   on the runner.
3. Sign each binary:
   `codesign --force --timestamp --options runtime -i <identifier> --sign "Developer ID Application: OmarKnows LLC (N9DRSTM2U6)"`.
   Hardened runtime (`--options runtime`) and a secure timestamp are both
   notarization prerequisites.
4. Assemble and sign `PIMHelper.app` the same way, universal launcher included.
5. Notarize with `xcrun notarytool submit --wait`, authenticating with an App
   Store Connect API key (`APPLE_NOTARY_KEY_P8_BASE64`, `APPLE_NOTARY_KEY_ID`,
   `APPLE_NOTARY_ISSUER_ID`).
6. Emit `apple-pim-clis-<version>-universal.zip`, `PIMHelper-<version>.zip`, and
   a `SHA256SUMS` file.
7. Create a **draft** GitHub release for the tag carrying those assets. No
   workflow creates releases today; publishing notes stays a manual step, but
   the assets now have a home.

#### Verified prerequisites

Both of these were established by running the recipe end-to-end against the real
certificate on 2026-09-04. Both fail in ways that are hard to diagnose from CI
logs, so they are requirements, not suggestions.

**The `.p12` must be produced by `/usr/bin/openssl` (LibreSSL), not OpenSSL 3.**
Homebrew's OpenSSL 3.6.4 writes a PKCS12 that macOS refuses:

```
security import a.p12  ->  SecKeychainItemImport: MAC verification failed
                           during PKCS12 import (wrong password?)
```

The password is correct — OpenSSL reads the file back fine. macOS cannot verify
OpenSSL 3's default SHA-256 PKCS12 MAC. Forcing legacy algorithms
(`-macalg sha1 -descert`) does not fix it either; the import then fails with
`Unknown format in import`. The system LibreSSL binary at `/usr/bin/openssl`
works with default options and is present on GitHub's macOS runners.

**The signing keychain must be added to the search list.** `codesign --keychain`
alone is insufficient — it resolves identities through the search list and fails
with `no identity found`. The job must run
`security list-keychains -d user -s "$KC" "$LOGIN"` before signing and restore
the original list afterwards, in a step that runs even on failure.

The validated sequence, which produced a correctly signed universal-ready binary:

```
security create-keychain -p "$KCPASS" "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import devid.p12 -k "$KC" -P "$P12PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC"
security list-keychains -d user -s "$KC" "$LOGIN"
codesign --force --timestamp --options runtime -i <identifier> \
         --sign "Developer ID Application: OmarKnows LLC (N9DRSTM2U6)" <binary>
```

Confirmed output: `TeamIdentifier=N9DRSTM2U6`, `Runtime Version` set,
`Timestamp` present, `codesign --verify --strict` passes, and the designated
requirement is

```
identifier "com.omarshahine.apple-pim.calendar-cli" and anchor apple generic
and certificate 1[field.1.2.840.113635.100.6.2.6] and
certificate leaf[field.1.2.840.113635.100.6.1.13] and
certificate leaf[subject.OU] = N9DRSTM2U6
```

Not stapled. `stapler` cannot staple a bare Mach-O — only bundles, `.dmg`, or
`.pkg`. A zip fetched with `curl` carries no `com.apple.quarantine` attribute, so
Gatekeeper never performs the check that stapling would satisfy offline.
Notarization still covers the browser-download case via online lookup. The
helper bundle *is* stapleable and will be stapled; the bare CLIs will not.

### 3. Verified install path

`setup.sh` gains a preferred path: download the version-matched asset from the
release for the current package version, verify it, and install it. On any
failure it falls back to today's `swift build`, so an offline machine or a
version without a signed release still works.

Verification, in `scripts/verify-signed-clis.sh`, must assert all three:

1. `codesign --verify --strict` passes.
2. `TeamIdentifier` equals `N9DRSTM2U6`.
3. Each binary's identifier matches its expected constant.

Checking only "is it signed" would accept a binary signed with an attacker's own
Developer ID. The team and identifier pins are the security boundary, and the
installer must refuse rather than fall back to installing an unverified binary.

Install location is unchanged (`~/.local/bin`), so existing `setup.sh` users keep
their path-keyed grant row and only absorb the requirement change.

### 4. Homebrew formula

The formula stops compiling and installs the signed prebuilt zip. It drops
`depends_on xcode: :build` and the vendored `swift-argument-parser` resource,
which exist only to make an offline source build work.

`publish-homebrew.yml` currently rewrites `url`/`sha256` to point at the GitHub
**source tarball**. It must instead point at the signed release asset, and must
run after the signing job rather than in parallel with it.

Homebrew preserves the signature. Verified three ways:

- `bun`, `discrawl`, and `freeze` in `/opt/homebrew/bin` all carry third-party
  Developer ID signatures that pass `codesign --verify --strict`. `discrawl` is a
  prebuilt-binary tap formula with the exact DR shape this design produces.
- Homebrew's only re-signing path is `codesign_patched_binary`, reached solely
  from `keg_relocate.rb` for binaries whose linkage it has patched.
- `otool -L calendar-cli` shows zero Homebrew-prefix references — only `/usr/lib`
  and `/System`. There is nothing to relocate, so nothing is re-signed.

Homebrew users' binaries move from a compiled-in-place keg to
`/opt/homebrew/bin`, a different path, so they re-grant once.

**Prior art: `steipete/imsg`.** It ships a universal, Developer ID signed,
notarized CLI as a release zip and points a tap formula at it — the same shape
this design proposes, already working in production. Two details taken from it:

- The formula declares `preserve_rpath`. Homebrew's `keg_relocate` rewrites
  rpaths, and rewriting triggers `codesign_patched_binary`, which re-signs
  ad-hoc and would put us straight back on cdhash pins.
- The formula body is `bin.install` of prebuilt binaries with no
  `depends_on xcode: :build`.

Our binaries carry 3 `LC_RPATH` entries per slice (`/usr/lib/swift`,
`@loader_path`, and the Xcode toolchain path). Critically they are 3 *per
slice*, not duplicated within a slice, so Homebrew's "strip duplicate rpaths"
path (`keg_relocate.rb:109-115`) does not fire — which is consistent with
`bun`, `discrawl`, and `freeze` all keeping verifiable signatures after
install. `preserve_rpath` is therefore insurance rather than a fix.

Because that insurance is against a *silent* regression, the formula's
`test do` block must assert the signature survives installation:

```ruby
test do
  system "codesign", "--verify", "--strict", bin/"calendar-cli"
  assert_match "N9DRSTM2U6", shell_output("codesign -dvvv #{bin}/calendar-cli 2>&1")
end
```

Without that, a future Homebrew change that re-signs our binaries would
reintroduce the original bug with no failing test anywhere.

Note also that `imsg` installs to `libexec` and writes a `bin` exec script,
because it ships a dylib. We must NOT copy that: TCC keys on the real binary
path, so a wrapper would record grants against the `libexec` path. Install
directly into `bin`.

### 5. `doctor.sh` signing check

For each installed CLI and the helper, print the designated requirement and
classify it:

- identifier + Team `N9DRSTM2U6` → healthy.
- `cdhash H"…"` → warn: *ad-hoc signed; your permission grants will be dropped on
  the next upgrade. Re-run `./setup.sh` to install signed binaries.*
- signed by any other team → error.

This converts today's silent, mystifying re-prompt into a diagnosable condition.

### 6. Migration

One re-approval, once. `setup.sh` prints an explicit notice before installing
signed binaries for the first time: permissions will be requested again because
the binaries are now certificate-signed, and this is the last time an upgrade
will ask.

`doctor.sh` flags ad-hoc installs as upgradeable so users who do not run
`setup.sh` still discover the fix.

## Testing

`scripts/check-signing.sh` asserts every installed CLI's designated requirement
is identifier-based rather than cdhash-based, and that the team matches. Used by
both `doctor.sh` and CI.

- **Unit**: requirement-classification logic (identifier / cdhash / wrong team)
  against captured `codesign -d -r-` fixtures. No signing, no TCC, runs on Linux.
- **Negative**: the installer refuses an ad-hoc-signed zip and refuses a
  correctly-signed zip with an unexpected identifier. Fixtures are ad-hoc signed
  locally, so no certificate is needed.
- **CI**: on PRs the signing job skips for lack of secrets; the classifier still
  runs against locally built binaries and asserts the expected-ad-hoc baseline.
  On tags, a post-sign step asserts every artifact verifies, is universal
  (`lipo -archs`), and reports the expected team before upload.

## Risks

**Identifier or team change is a silent mass revocation.** Nothing in the build
fails; every user simply loses their grants. Mitigated by keeping both in one
constants file with a comment saying so, and by CI asserting the signed output
matches the expected values before upload.

**Certificate compromise.** The `.p12` and the notary key live in repo secrets.
Scoped to a throwaway keychain deleted on every run, but a repo compromise means
signing capability. Standard for this kind of pipeline; worth knowing.

**Notarization latency and flakiness.** `notarytool submit --wait` can take
minutes and Apple's service has outages. The signing job failing must not block
the npm and ClawHub publishes, which do not depend on it.

**Homebrew formula rewrite is cross-repo.** The formula lives in
`omarshahine/homebrew-tap`. The tap change and the first signed release have to
land in the right order or `brew install` breaks — the formula must not point at
a release asset that does not exist yet.

## Open questions

- Should the signed zip carry the four CLIs only, or also a `VERSION` file so the
  installer can detect a mismatched download without parsing the filename?
- Does the npm/ClawHub path want the signed binaries too, or is fetching from the
  GitHub release at `setup.sh` time sufficient for those users?

## Rollout order

1. ~~Recover the Developer ID Application cert and store the p12 repo secrets.~~ Done
   2026-09-04: cert regenerated (valid to 2031-09-05), `APPLE_DEVELOPER_ID_P12_BASE64`
   and `APPLE_DEVELOPER_ID_P12_PASSWORD` set. Notary key secrets still outstanding.
2. Land the signing job and cut one tag. Confirm assets are produced, verify, and
   are universal. Do not touch the formula yet.
3. Land `verify-signed-clis.sh`, the `setup.sh` fetch path, and the `doctor.sh`
   check. Verify locally that a re-grant sticks across a rebuild.
4. Update the tap formula and `publish-homebrew.yml` last, once a signed asset
   demonstrably exists for the current version.
