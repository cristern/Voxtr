# Device-action signing evidence (#114)

This isolated test tool signs `session_issue`, `session_renew`, `hydration_get`
and `hydration_ack` with **actual Apple Swift CryptoKit on a Codemagic Mac**.
It uses public, deterministic test-only private scalars 1 and 2, never a device
key. CryptoKit's signature nonce need not be deterministic. Each execution
exports the exact UTF-8 bytes/hex, nonce, 65-byte X9.63 public key, 64-byte
P1363 signature and valid but wrong public key in `swift-fixtures.json`.

`Scripts/DeviceActions/verify.ts` recomputes the expected bytes with the
unchanged production backend builder and invokes its unchanged production
P-256 verifier. All three modules under `backend/` were retrieved at backend
#12's merged revision `419f70e80b69ae524edb066e367093b1b8455a9a`.
`backend-pin.json` records their upstream Git blob IDs and SHA-256 hashes;
`check_pin.py` rejects modifications. No backend changes are required.

The Swift builder is **test-only**: current iOS develop has no production
device-action builder. #110 must test its eventual actual production builder
against these same frozen bytes. The existing production claim-proof builder
and its reverse-direction fixture are untouched.

## Executable checks

On a Mac with Swift CryptoKit and Deno 2.9.6:

```sh
python3 Scripts/DeviceActions/check_pin.py
mkdir -p build/device-action-evidence
export FIXTURE_IOS_REVISION=$(git rev-parse HEAD)
xcrun swift Scripts/DeviceActions/sign.swift build/device-action-evidence/swift-fixtures.json
deno run --no-config --allow-read Scripts/DeviceActions/verify.ts build/device-action-evidence/swift-fixtures.json
```

The `device-action-signing-evidence` workflow runs only on pushes to the exact
#114 branch and is also manually runnable. It exports fixtures, full iOS SHA,
backend hashes, macOS/Swift/Deno versions, signing/verification logs and fixture
SHA-256. No app build/signing, credentials, deployment or publication occurs.

Acceptance requires **actual executed CI output**, not merely these authored
scripts. Expected output is 4 positive proofs accepted and 32 negatives rejected
(wrong action, version, grant, challenge, nonce, missing final newline, CRLF and
a genuinely wrong key for each action). Swift checks uppercase/lowercase UUID
inputs, exact frozen UTF-8/LF bytes, URL-safe `-_` encoding and padding removal.
Deno checks canonical unpadded base64url for every exported binary field.

This does not validate a session client, physical Secure Enclave, hosted
endpoints, hydration, membership, offline policy, CloudKit or TestFlight gates.
