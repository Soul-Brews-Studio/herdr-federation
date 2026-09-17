/**
 * This node's identity: an ed25519 keypair generated once and kept forever.
 *
 * The keypair is not used to sign every request — that would be a per-message
 * cost for a private mesh that already runs over NetBird. It is used exactly
 * once per relationship, when an invite is redeemed, to prove that whoever is
 * redeeming actually holds the key they claim. After that the relationship
 * rides on the token issued at redemption.
 *
 * Why bother with a key at all, then: a *ban* has to outlive a token. Tokens
 * are handed out and revoked; the pubkey is the stable thing a ban can pin to,
 * so a banned node cannot simply redeem a fresh invite under the same name.
 */

import { createPublicKey, createPrivateKey, generateKeyPairSync, randomBytes, sign as edSign, verify as edVerify } from "node:crypto";

export type Identity = {
  node: string;
  /** raw ed25519 public key, hex — what peers pin and what bans reference */
  pubkey: string;
  /** first 16 hex chars, for humans reading a screen */
  fingerprint: string;
};

/** ed25519 SPKI DER is a fixed 12-byte header followed by the raw 32-byte key. */
const SPKI_PREFIX = Buffer.from("302a300506032b6570", "hex");

const rawFromSpki = (der: Buffer) => der.subarray(der.length - 32);

function publicKeyFromRaw(raw: Buffer) {
  // rebuild the DER around a peer's 32 raw bytes so node:crypto will take it
  const der = Buffer.concat([SPKI_PREFIX, Buffer.from([0x03, 0x21, 0x00]), raw]);
  return createPublicKey({ key: der, format: "der", type: "spki" });
}

export const fingerprint = (pubkeyHex: string) => pubkeyHex.slice(0, 16);

export class NodeIdentity {
  private constructor(
    readonly node: string,
    readonly pubkey: string,
    readonly privatePem: string,
  ) {}

  /** Load the keypair from disk, or make one on first boot and persist it. */
  static async open(node: string, path: string): Promise<NodeIdentity> {
    try {
      const saved = (await Bun.file(path).json()) as { privateKey: string; pubkey: string };
      if (saved.privateKey && saved.pubkey) return new NodeIdentity(node, saved.pubkey, saved.privateKey);
    } catch {
      // first boot
    }
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const pubkey = rawFromSpki(publicKey.export({ type: "spki", format: "der" }) as Buffer).toString("hex");
    const privatePem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    await Bun.write(path, JSON.stringify({ pubkey, privateKey: privatePem, createdAt: new Date().toISOString() }, null, 2));
    return new NodeIdentity(node, pubkey, privatePem);
  }

  get identity(): Identity {
    return { node: this.node, pubkey: this.pubkey, fingerprint: fingerprint(this.pubkey) };
  }

  sign(message: string): string {
    const key = createPrivateKey(this.privatePem);
    return edSign(null, Buffer.from(message), key).toString("base64url");
  }
}

/** Verify a signature against a peer's raw hex pubkey. Never throws — a malformed key is just false. */
export function verify(message: string, signature: string, pubkeyHex: string): boolean {
  try {
    const raw = Buffer.from(pubkeyHex, "hex");
    if (raw.length !== 32) return false;
    return edVerify(null, Buffer.from(message), publicKeyFromRaw(raw), Buffer.from(signature, "base64url"));
  } catch {
    return false;
  }
}

/** The secret in an invite link, and the token a membership rides on. */
export const secret = () => randomBytes(24).toString("base64url");
