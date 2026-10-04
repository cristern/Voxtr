import { buildDeviceSessionCanonicalMessageBytes, type DeviceSessionAction } from "../../Tests/Fixtures/DeviceActions/backend/canonicalMessage.ts";
import { verifyP256Signature } from "../../Tests/Fixtures/DeviceActions/backend/p256.ts";
import { decodeBase64Url, encodeBase64Url } from "../../Tests/Fixtures/DeviceActions/backend/base64url.ts";
function check(value: boolean, label: string): asserts value {
  if (!value) throw new Error(label);
}
function decode(value: string): Uint8Array {
  const bytes = decodeBase64Url(value);
  check(bytes !== null && encodeBase64Url(bytes) === value, "canonical base64url");
  return bytes;
}
const artifact = JSON.parse(await Deno.readTextFile(Deno.args[0]));
check(artifact.backendRevision === "419f70e80b69ae524edb066e367093b1b8455a9a", "backend revision");
check(artifact.producer === "Swift CryptoKit on macOS", "producer");
const actions: DeviceSessionAction[] = ["session_issue", "session_renew", "hydration_get", "hydration_ack"];
check(artifact.fixtures.length === 4, "four fixtures required");
let rejected = 0;
for (const [index, f] of artifact.fixtures.entries()) {
  check(f.action === actions[index], "exact action coverage/order");
  const fields = {action: actions[index], deviceGrantId: f.deviceGrantId, challengeId: f.challengeId, nonce: decode(f.nonce)};
  const bytes = buildDeviceSessionCanonicalMessageBytes(fields);
  const hex = Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
  check(hex === f.messageHex && new TextDecoder().decode(bytes) === f.messageUtf8, "Swift bytes match production builder");
  check(f.messageUtf8.split("\n")[0] === f.version, "version line");
  const key = decode(f.publicKey), signature = decode(f.signature);
  check(key.length === 65 && key[0] === 4 && signature.length === 64, "wire lengths");
  check((await verifyP256Signature(key, signature, bytes)).ok, `positive ${f.action}`);
  const encode = (s: string) => new TextEncoder().encode(s);
  const changedNonce = fields.nonce.slice(); changedNonce[0] ^= 1;
  const negatives = [
    buildDeviceSessionCanonicalMessageBytes({...fields, action: actions[(index + 1) % 4]}),
    encode(f.messageUtf8.replace(f.version, f.version + "-wrong")),
    buildDeviceSessionCanonicalMessageBytes({...fields, deviceGrantId: "abcdefab-cdef-abcd-efab-cdefabcdefac"}),
    buildDeviceSessionCanonicalMessageBytes({...fields, challengeId: "fedcbafe-dcba-fedc-bafe-dcbafedcbaff"}),
    buildDeviceSessionCanonicalMessageBytes({...fields, nonce: changedNonce}),
    bytes.slice(0, -1), encode(f.messageUtf8.replaceAll("\n", "\r\n")),
  ];
  for (const mutation of negatives) {
    const result = await verifyP256Signature(key, signature, mutation);
    check(!result.ok && result.reason === "signature_invalid", `mutation rejected ${f.action}`); rejected++;
  }
  const wrongKey = await verifyP256Signature(decode(f.wrongPublicKey), signature, bytes);
  check(!wrongKey.ok && wrongKey.reason === "signature_invalid", "genuine wrong key"); rejected++;
}
console.log(`PASS: 4 Swift signatures accepted; ${rejected} negative proofs rejected by pinned production Deno verifier`);
