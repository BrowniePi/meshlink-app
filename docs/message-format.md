# MeshLink Message Format v0.1

Transport-agnostic binary envelope used by every device on the MeshLink network. The same struct is transmitted over BLE, the node WiFi backhaul, and the socket transport adapter used in Phase 0. All multi-byte integers are big-endian.

---

## 1. Size budget and BLE constraint

BLE 5.0 with negotiated ATT MTU of 247 bytes gives 244 bytes of usable payload per ATT Write Command. MeshLink messages that exceed 244 bytes are fragmented into at most two GATT writes by the transport layer; the receiver reassembles before passing to the relay pipeline. The relay pipeline imposes a hard ceiling of 460 bytes to bound reassembly complexity and prevent store-and-forward buffer abuse.

| Budget item | Bytes |
|-------------|------:|
| Fixed header (fields before payload) | 75 |
| Max payload | 321 |
| Signature | 64 |
| **Max packet total** | **460** |

321 bytes of payload accommodates a 300-character ASCII text message with 21 bytes to spare. Multi-byte UTF-8 characters consume more bytes per character; the 300-char UI limit is enforced in the app layer, not here.

---

## 2. Packet layout

```
Offset  Len   Field
------  ----  -----------
     0    16  msg_id
    16    32  sender_key
    48    16  ephem_id
    64     4  timestamp
    68     1  ttl
    69     1  spray_L
    70     2  zone_id
    72     1  msg_type
    73     2  payload_len
    75   0–321 payload
75+N    64  signature
```

`N` = value of `payload_len`. Total packet length = 75 + N + 64 = **139 + N bytes**.

---

## 3. Field definitions

### `msg_id` — offset 0, 16 bytes

Content-addressable identifier derived as:

```
msg_id = BLAKE3(sender_key ‖ timestamp_bytes ‖ msg_type_byte ‖ payload)[0:16]
```

`timestamp_bytes` is the 4-byte big-endian encoding of `timestamp`. `msg_type_byte` is the 1-byte encoding of `msg_type`. Any relay can recompute and verify the `msg_id`. Used as the deduplication key in the relay pipeline Bloom filter.

### `sender_key` — offset 16, 32 bytes

Curve25519 public key. The sender's long-term identity. Never rotated; bound to a ticket-based attestation token at Phase 5. **Never appears in BLE advertising packets** — only in the message envelope transmitted over an established connection.

### `ephem_id` — offset 48, 16 bytes

16-byte random identifier generated on first app launch and rotated every 15 minutes, aligned with iOS BLE RPA rotation. Used by relay nodes for per-sender rate-limiting and deduplication without exposing `sender_key` on the radio. The rotation boundary is time-based (`floor(unix_time / 900)`), so any two devices produce the same rotation boundaries.

### `timestamp` — offset 64, 4 bytes, uint32

Unix time in whole seconds at the moment the message was created. The relay pipeline drops messages with `timestamp` more than 5 minutes in the past or more than 30 seconds in the future (replay attack prevention, pipeline step 3).

### `ttl` — offset 68, 1 byte, uint8

Remaining relay hop budget. Set by the originating device; decremented by 1 at each relay. A relay that receives a message with `ttl == 0` drops it (pipeline step 2). Typical initial values: 5 (Cases 1–2), 8 (Case 3).

### `spray_L` — offset 69, 1 byte, uint8

Spray-and-Wait copy budget. Set by the originating device. Each relay applies the binary split rule: it gives a peer `floor(spray_L / 2)` copies and keeps `ceil(spray_L / 2)`. When `spray_L` reaches 1, the device enters the Wait phase and only delivers directly to the destination. **A relay must never write a value of `spray_L` higher than the value it received**; inflation is treated as an attack and causes a ban. Typical values: 1 (Case 1, direct delivery), 8–16 (Case 2), 16–32 (Case 3).

### `zone_id` — offset 70, 2 bytes, uint16

Destination zone identifier. Assigned to each Pi node at deployment. `0xFFFF` is the broadcast address (venue-wide announcements); all nodes receive and flood to their connected phones. `0x0000` is reserved. Cross-zone messages are forwarded over the batman-adv backhaul to the destination zone's node.

### `msg_type` — offset 72, 1 byte, uint8

Message type enum. Determines payload structure. See section 4.

### `payload_len` — offset 73, 2 bytes, uint16

Length of the `payload` field in bytes. Must satisfy `0 ≤ payload_len ≤ 321`. A relay drops any packet where `payload_len > 321` or where the actual packet length does not equal `139 + payload_len`.

### `payload` — offset 75, variable

Type-specific content. Structure determined by `msg_type`. See section 4.

### `signature` — offset 75+N, 64 bytes

Ed25519 signature (libsodium `crypto_sign_ed25519`) over the signed region:

```
signed_region = bytes[0 : 75 + payload_len]
```

i.e., every field in the packet except `signature` itself. The signing key is the sender's long-term Ed25519 private key (the keypair whose public half is `sender_key`). Verified at relay pipeline step 6.

---

## 4. `msg_type` enum and payload formats

| Value | Name | Description |
|------:|------|-------------|
| `0x01` | TEXT | Plain text message from one user to another or to a zone |
| `0x02` | LOCATION | Live location ping |
| `0x03` | ACK | Delivery acknowledgement — suppresses remaining spray copies |
| `0x04` | ACK_SUPPRESS | Forwarded ACK suppression signal (depth ≤ 2 from original ACK emitter) |
| `0x05` | ANNOUNCEMENT | Venue-wide broadcast from organiser; always paired with `zone_id = 0xFFFF` |

### TEXT and ANNOUNCEMENT payload

Raw UTF-8 bytes. No null terminator. Length = `payload_len`. The app layer enforces a 300-character display limit; the protocol enforces only the 321-byte byte limit.

### LOCATION payload (10 bytes)

| Offset | Len | Field | Type | Description |
|-------:|----:|-------|------|-------------|
| 0 | 4 | `lat_microdeg` | int32 BE | Latitude × 10⁶ (e.g. 51.503298° → 51503298) |
| 4 | 4 | `lon_microdeg` | int32 BE | Longitude × 10⁶, signed (e.g. −0.127144° → −127144) |
| 8 | 2 | `accuracy_m` | uint16 BE | Horizontal accuracy in metres; `0` = unknown |

### ACK payload (16 bytes)

| Offset | Len | Field | Description |
|-------:|----:|-------|-------------|
| 0 | 16 | `acked_msg_id` | `msg_id` of the message being acknowledged |

### ACK_SUPPRESS payload (16 bytes)

Identical structure to ACK. Distinguished by `msg_type` so relays know not to re-broadcast further (suppression terminates at depth 2).

---

## 5. Worked examples

All examples use the following shared context:

- **Timestamp:** `0x6A348680` = 2026-06-19 00:00:00 UTC
- **Zone:** `0x0003` (Zone 3, main stage area)
- **Alice's Curve25519 pubkey (sender_key):** abbreviated as `a1b2c3d4 e5f60718 293a4b5c 6d7e8f90 a1b2c3d4 e5f60718 293a4b5c 6d7e8f90`
- **Alice's ephemeral ID (ephem_id):** abbreviated as `f0e1d2c3 b4a59687 78695a4b 3c2d1e0f`

### Example 1 — TEXT message

Alice sends "Meet at south gate" (18 bytes UTF-8) to Zone 3.

```
msg_id      = BLAKE3(sender_key ‖ 6a348680 ‖ 01 ‖ payload)[0:16]
            → 3f4a5b6c 7d8e9fa0 b1c2d3e4 f5061728   (example value)

sender_key  = a1b2c3d4 e5f60718 293a4b5c 6d7e8f90
              a1b2c3d4 e5f60718 293a4b5c 6d7e8f90   (32 bytes)

ephem_id    = f0e1d2c3 b4a59687 78695a4b 3c2d1e0f   (16 bytes)

timestamp   = 6a 34 86 80                            2026-06-19 00:00:00 UTC
ttl         = 05                                     5 hops
spray_L     = 08                                     L = 8 (Case 2)
zone_id     = 00 03                                  Zone 3
msg_type    = 01                                     TEXT
payload_len = 00 12                                  18 bytes

payload     = 4d 65 65 74 20 61 74 20                "Meet at "
              73 6f 75 74 68 20 67 61                "south ga"
              74 65                                  "te"

signature   = [64 bytes: Ed25519 sig over bytes 0–92]
```

**Total: 75 + 18 + 64 = 157 bytes**

### Example 2 — LOCATION ping

Alice broadcasts her location: 51.503298°N, 0.127144°W, accuracy 5 m.

```
msg_id      = BLAKE3(sender_key ‖ 6a348680 ‖ 02 ‖ payload)[0:16]
            → 9c8d7e6f 5a4b3c2d 1e0fa0b1 c2d3e4f5   (example value)

sender_key  = a1b2c3d4 ...                           (32 bytes, same as Ex 1)
ephem_id    = f0e1d2c3 ...                           (16 bytes, same rotation window)

timestamp   = 6a 34 86 80
ttl         = 03                                     3 hops (location stays local)
spray_L     = 01                                     L = 1 (direct delivery to node)
zone_id     = 00 03
msg_type    = 02                                     LOCATION
payload_len = 00 0a                                  10 bytes

payload:
  lat_microdeg  = 03 11 e0 c2                        51503298  → 51.503298°N
  lon_microdeg  = ff fe 0f 58                        −127144   → −0.127144°W
  accuracy_m    = 00 05                              5 metres

signature   = [64 bytes: Ed25519 sig over bytes 0–84]
```

**Total: 75 + 10 + 64 = 149 bytes**

### Example 3 — ACK

Phone B acknowledges receipt of Alice's text message from Example 1.

```
msg_id      = BLAKE3(sender_key_B ‖ 6a348681 ‖ 03 ‖ payload)[0:16]
            → 77a8b9ca db0e1f20 31425364 75869708   (example value)

sender_key  = b9c8d7e6 ...                           (32 bytes, Bob's pubkey)
ephem_id    = 01234567 89abcdef 01234567 89abcdef   (16 bytes)

timestamp   = 6a 34 86 81                            1 second after original
ttl         = 03                                     3 hops (ACK propagates back)
spray_L     = 01                                     ACK is not sprayed
zone_id     = 00 03
msg_type    = 03                                     ACK
payload_len = 00 10                                  16 bytes

payload:
  acked_msg_id = 3f 4a 5b 6c 7d 8e 9f a0            msg_id from Example 1
                 b1 c2 d3 e4 f5 06 17 28

signature   = [64 bytes: Ed25519 sig over bytes 0–90]
```

**Total: 75 + 16 + 64 = 155 bytes**

---

## 6. Relay pipeline size checks

The relay pipeline (step 1) drops packets outside `[131, 460]` bytes as a fast pre-parse check. The true minimum for a structurally valid packet is **139 bytes** (75-byte header + 0-byte payload + 64-byte signature). The lower bound of 131 catches obviously truncated packets that don't even reach the end of the fixed header. Any packet in the range `[131, 138]` bytes will pass the size check but fail the subsequent `payload_len` consistency check (`139 + payload_len ≠ packet_length`) and be dropped there.

| Constraint | Value |
|------------|------:|
| Min valid packet (empty payload) | 139 bytes |
| Min valid packet (practical: ACK has 16-byte payload) | 155 bytes |
| Max packet | 460 bytes |
| Fixed overhead (header + signature) | 139 bytes |
| Max payload | 321 bytes |
| Max UTF-8 text payload | 321 bytes (~300 ASCII chars) |
