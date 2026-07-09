"""Generate test/fixtures/friendship_parity_vectors.json from the Python
reference implementation in meshlink-core (Friendship branch).

The Dart port in lib/core/{capability_token,sealed,friend_wire}.dart must
consume these bytes identically — test/friendship_parity_test.dart replays
them. Regenerate with:

    ../MeshLink-core/.venv/bin/python tool/gen_friendship_vectors.py

All seeds below are throwaway fixture data generated for this file only —
they are not key material for any real identity (the app generates real keys
on-device at first launch and they never leave the Keychain/Keystore).
"""

from __future__ import annotations

import json
import pathlib
import sys

CORE = pathlib.Path(__file__).resolve().parents[2] / "MeshLink-core"
sys.path.insert(0, str(CORE))

from nacl.public import PrivateKey  # noqa: E402
from nacl.signing import SigningKey  # noqa: E402

from capability.token import issue  # noqa: E402
from crypto.sealed import seal  # noqa: E402
from friends.wire import (  # noqa: E402
    FriendRequestPayload,
    encode_direct_message,
    encode_friend_request,
)
from location.wire import LocationResponsePayload, encode_location_response  # noqa: E402

OUT = pathlib.Path(__file__).resolve().parents[1] / "test" / "fixtures" / \
    "friendship_parity_vectors.json"

ISSUER_ED_SEED = bytes(range(32))
GRANTEE_ED_SEED = bytes(range(32, 64))
RECIPIENT_X_SEED = bytes(range(64, 96))
SENDER_X_SEED = bytes(range(96, 128))
ISSUED_AT = 1751400000
NONCE = bytes.fromhex("0011223344556677")
HINT = bytes.fromhex("a1a2a3a4a5a6a7a8")


def main() -> None:
    issuer = SigningKey(ISSUER_ED_SEED)
    grantee = SigningKey(GRANTEE_ED_SEED)
    recipient_x = PrivateKey(RECIPIENT_X_SEED)
    sender_x = PrivateKey(SENDER_X_SEED)

    token = issue(
        issuer,
        bytes(grantee.verify_key),
        issued_at=ISSUED_AT,
        nonce=NONCE,
    )

    sealed_plaintext = b"parity check: sealed envelope"
    sealed = seal(sealed_plaintext, bytes(recipient_x.public_key))

    friend_request = encode_friend_request(
        FriendRequestPayload("ada-l", bytes(sender_x.public_key),
                             bytes(grantee.verify_key)),
        HINT,
        bytes(recipient_x.public_key),
    )

    direct_message = encode_direct_message(
        "meet at gate B ☕", HINT, bytes(recipient_x.public_key))

    location_response = encode_location_response(
        LocationResponsePayload(
            lat_microdeg=37774900,
            lon_microdeg=-122419400,
            accuracy_m=12,
            beacon_age_s=40,
            zone_id=0xFFFF,
        ),
        HINT,
        bytes(recipient_x.public_key),
    )

    OUT.write_text(json.dumps({
        "generator": "tool/gen_friendship_vectors.py @ meshlink-core Friendship",
        "note": "seeds are throwaway fixture data, not real key material",
        "token": {
            "issuer_ed25519_seed_hex": ISSUER_ED_SEED.hex(),
            "issuer_ed25519_pub_hex": bytes(issuer.verify_key).hex(),
            "grantee_ed25519_pub_hex": bytes(grantee.verify_key).hex(),
            "issued_at": ISSUED_AT,
            "expiry_s": 24 * 3600,
            "nonce_hex": NONCE.hex(),
            "token_hex": token.hex(),
        },
        "sealed": {
            "recipient_x25519_seed_hex": RECIPIENT_X_SEED.hex(),
            "plaintext_hex": sealed_plaintext.hex(),
            "sealed_hex": sealed.hex(),
        },
        "friend_request": {
            "recipient_x25519_seed_hex": RECIPIENT_X_SEED.hex(),
            "username": "ada-l",
            "sender_curve25519_pub_hex": bytes(sender_x.public_key).hex(),
            "sender_ed25519_pub_hex": bytes(grantee.verify_key).hex(),
            "hint_hex": HINT.hex(),
            "payload_hex": friend_request.hex(),
        },
        "direct_message": {
            "recipient_x25519_seed_hex": RECIPIENT_X_SEED.hex(),
            "text": "meet at gate B ☕",
            "hint_hex": HINT.hex(),
            "payload_hex": direct_message.hex(),
        },
        "location_response": {
            "requester_x25519_seed_hex": RECIPIENT_X_SEED.hex(),
            "lat_microdeg": 37774900,
            "lon_microdeg": -122419400,
            "accuracy_m": 12,
            "beacon_age_s": 40,
            "zone_id": 0xFFFF,
            "payload_hex": location_response.hex(),
        },
    }, indent=2) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
