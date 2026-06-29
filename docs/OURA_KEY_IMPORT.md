# Oura Ring auth-key import

**Pairing mode:** key import (Phase B — co-exist with the Oura app)
**Prerequisite:** Oura ring already paired with the official Oura app
**Platform:** iOS + macOS (Android: ADB path, see below)

---

## Why this exists

NOOP's default Oura pairing requires a **factory reset**: the ring's auth key is replaced with one NOOP generates, which severs the Oura app's link. That is the simplest and most reliable path.

Key import is the alternative. The Oura app's auth key (a 16-byte AES-128 secret, installed on the ring during its first pairing) is stored in the Oura app's local database on your device. If you can read it out, NOOP and the Oura app can both authenticate with the same ring — each connects independently, syncs, and disconnects. No factory reset needed.

> **Interoperability, not extraction.** The key is yours: the Oura app generated it from your ring's pairing session and stored it on your device, not on Oura's servers. Reading it back is no different from reading your own files. The extracted key only authenticates over the direct BLE link — it grants no access to your Oura account, cloud data, or anything else.

---

## How the auth works

Every Oura Ring Gen 3 / 4 / 5 uses a proprietary BLE auth sequence ([open_oura](https://github.com/Th0rgal/open_oura) reverse-engineering):

1. The app writes `reqAuthNonce` (`0x2F 0x02 0x01 0x2B`) to the ring's write characteristic.
2. The ring responds with a random 15-byte nonce.
3. The app PKCS7-pads the nonce to 16 bytes (pad value `0x01`), encrypts it with AES-128/ECB using the stored 16-byte key, and writes the result back.
4. The ring checks the ciphertext. A match means "authenticated"; a mismatch means "wrong key".

The ring only accepts **one** auth key at a time. Factory-reset mode (opcode `0x24`) lets a new key be installed; after that, only the holder of that key can authenticate.

---

## Step 1 — Extract the key with open_oura

[**open_oura**](https://github.com/Th0rgal/open_oura) is a community Rust project that reverse-engineered the protocol and ships a CLI for key extraction and direct ring access.

### Install the CLI

```bash
git clone https://github.com/Th0rgal/open_oura.git
cd open_oura
cargo build --release          # requires Rust ≥ 1.75
```

The binary lands at `target/release/open_oura` (or `open_oura.exe` on Windows). You can also `cargo install --path .` to put it in your PATH.

### iOS path (iTunes / Finder backup)

The Oura app stores the key inside its sandboxed app container in a Realm database. A local **unencrypted** backup exposes that container.

**1. Create an unencrypted backup.**

On macOS (Finder):
1. Connect your iPhone via USB.
2. Click your device in Finder → **General** tab → **Back Up Now**.
3. Confirm that "Encrypt local backup" is **off**. If it is on, tick it off, set a temporary password, back up, then re-enable it afterwards.

On Windows (iTunes):
1. iTunes → device icon → **Summary** → **Back Up Now**.
2. Ensure "Encrypt iPhone backup" is unchecked.

> Encrypted backups are unreadable by third-party tools. The backup must be unencrypted for this step.

**2. Run the open_oura extraction.**

```bash
# Let open_oura find the most recent iTunes backup automatically:
./target/release/open_oura extract-key

# Or point it at a specific backup directory:
./target/release/open_oura extract-key --backup ~/Library/Application\ Support/MobileSync/Backup/<device-uuid>
```

> The exact CLI flags may differ across open_oura releases. Run `open_oura --help` or check [the project's README](https://github.com/Th0rgal/open_oura) for the current syntax.

The tool walks the backup manifest, finds the `com.ouraring.oura` app container, opens the Realm database file, and prints the auth key:

```
Ring serial : XXXXXXXX
Auth key    : a1b2c3d4e5f60718293a4b5c6d7e8f90
```

Copy the 32-character hex string. That is the key.

### Android path (ADB backup)

**1. Enable USB debugging** on your Android device (Settings → Developer options → USB debugging).

**2. Back up the Oura app data.**

```bash
adb backup -noapk com.ouraring.oura -f oura_backup.ab
```

Some Android versions prompt you to set a backup password on-device; leave it blank or note the password — you will need it to unpack.

**3. Unpack and extract.**

```bash
# Convert the Android backup to a readable tar:
java -jar abe.jar unpack oura_backup.ab oura_backup.tar

# Or use open_oura directly:
./target/release/open_oura extract-key --adb-backup oura_backup.ab
```

`abe.jar` is the [Android Backup Extractor](https://github.com/nelenkov/android-backup-extractor). Again, check the open_oura README for the current command.

### Manual extraction (if the CLI doesn't support your version)

If open_oura's extraction command doesn't work with your Oura app version, you can read the key directly from the Realm database:

1. Locate the Oura app container in the backup. On iOS the backup stores files by `SHA1("AppDomain-com.ouraring.oura" + "-" + relative/path/in/app)`; the Realm file is typically `Documents/Data.realm` or `Library/Application Support/*.realm`.
2. Open the `.realm` file with [Realm Studio](https://www.mongodb.com/products/tools/realm-studio) (free).
3. Look for a table named `Ring`, `Device`, or `PairingKey`. The key is stored as a UUID string or as raw bytes. If stored as a UUID (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`), convert it to 16 bytes in little-endian order — open_oura's source has the exact conversion if you need it.

---

## Step 2 — Import the key into NOOP

> **Note:** The key-import UI (Phase B) is not yet shipped in NOOP. The steps below describe the flow as it will work once the UI lands. If you are testing before release, use the developer workaround at the bottom of this page.

**In-app import flow (once Phase B ships):**

1. Open NOOP → **Devices** → tap **+** → choose **Oura ring**.
2. On the prep screen, tap **"I already use the Oura app"** (instead of "Factory reset").
3. Paste the 32-character hex key from Step 1 into the key field.
4. Tap **Import** — NOOP saves the key to your device's Keychain under `noop.oura.authkey / oura-<ring-uuid>`.
5. NOOP scans for the ring. Bring it near your device (remove it from the charger; force-quit the Oura app so it isn't holding the BLE connection).
6. The ring authenticates, NOOP drains your HR / SpO₂ / skin-temperature history, and the device appears in your Devices screen.

---

## Developer workaround (before Phase B UI ships)

If you want to test key import before the in-app UI is built, you can write the key to the Keychain directly using `security` on macOS:

```bash
# Replace <ring-uuid> with the UUID of your ring's CBPeripheral (shown in BLE scan logs)
# and <hex-key> with the 32-character hex string from Step 1.

security add-generic-password \
  -s "noop.oura.authkey" \
  -a "oura-<ring-uuid>" \
  -w "<hex-key>" \
  -T "" \
  ~/Library/Keychains/login.keychain-db
```

Then add the Oura ring as a device in NOOP (skip the factory-reset instructions — the key is already in the Keychain). NOOP's auth flow reads the key from `noop.oura.authkey / oura-<ring-uuid>` and will authenticate directly without trying to install a new key.

For iOS simulator or a device build during development, you can inject the key via the `ouraAuthKeyFromHex(_:)` function in `OuraProtocol` and call `saveKey(_:)` directly in `OuraLiveSource` from a debug menu or test harness.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Authentication failed — wrong key` | Key mis-typed or truncated | Paste the key again; it must be exactly 32 hex characters, no spaces or colons. |
| `Ring rejected: not the original onboarded device` | Ring was re-paired (new key installed) after you extracted the old key | Run extraction again from a fresh backup taken after the latest Oura app pairing. |
| Ring not discovered during NOOP scan | Ring is in the charger dock, or Oura app is holding the BLE link | Remove from charger. Force-quit the Oura app. |
| Backup extraction fails — "encrypted backup" error | iTunes/Finder backup is encrypted | Turn off backup encryption, back up again, then re-enable it. |
| Realm file not found in backup | App stores the DB in a non-standard path on your Oura app version | Check open_oura issues; file a path-finding PR if you locate it manually. |
| NOOP connects but syncs 0 events | Cursor from a previous failed sync is past the newest event | Reset the cursor: `UserDefaults.standard.removeObject(forKey: "oura.cursor.oura-<ring-uuid>")` |

---

## What the key does and does not grant

| Grants | Does not grant |
|---|---|
| Authenticate over the direct BLE link to YOUR ring | Access to your Oura account or cloud data |
| Drain raw sensor events (HR, SpO₂, temperature) over BLE | Control the ring (no firmware update, no factory reset) |
| Read all historical events from the ring's flash | Any capability beyond what the BLE protocol exposes |

---

## Credits

The protocol understanding underpinning NOOP's Oura integration is built entirely on
[**Th0rgal/open_oura**](https://github.com/Th0rgal/open_oura) — a clean-room community
reverse-engineering of the Oura Gen 3/4/5 BLE protocol (TLV framing, AES-128/ECB nonce auth,
11-step sync sequence, 56+ event types). The NOOP `OuraProtocol` Swift package is an independent
reimplementation of those findings; no Oura source code was used.
