"""CLI entry point for the multi-device simulation harness.

Run with: python -m sim.harness --topology line --devices 5 \
    --inject device=0,payload=hello,zone_id=65535

See sim/README.md for full usage and how to add a new topology.
"""
import argparse
import os
import time

from sim.device import BROADCAST_ZONE, Device
from sim.topologies import line, mesh, star

ZONE_COUNT = 4

TOPOLOGIES = {
    "line": line.build,
    "star": star.build,
    "mesh": mesh.build,
}


def parse_inject_spec(spec: str) -> dict:
    """Parse 'device=0,payload=hello,ttl=5,spray_l=8,zone_id=65535,delay=0'."""
    fields = dict(pair.split("=", 1) for pair in spec.split(","))
    return {
        "device": int(fields["device"]),
        "payload": fields["payload"].encode(),
        "ttl": int(fields.get("ttl", 5)),
        "spray_l": int(fields.get("spray_l", 8)),
        "zone_id": int(fields.get("zone_id", BROADCAST_ZONE), 0),
        "delay": float(fields.get("delay", 0)),
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="MeshLink multi-device simulation harness")
    parser.add_argument("--devices", type=int, required=True, help="number of simulated devices")
    parser.add_argument("--topology", choices=sorted(TOPOLOGIES), required=True)
    parser.add_argument(
        "--inject",
        action="append",
        dest="injections",
        type=parse_inject_spec,
        required=True,
        help="device=I,payload=TEXT[,ttl=T][,spray_l=L][,zone_id=Z][,delay=SECONDS]; repeatable",
    )
    parser.add_argument("--wait", type=float, default=2.0, help="settle time after the last injection")
    return parser.parse_args(argv)


def build_devices(n: int, topology_name: str) -> list[Device]:
    adjacency = TOPOLOGIES[topology_name](n)
    devices = [Device(index=i, zone_id=i % ZONE_COUNT) for i in range(n)]

    for device in devices:
        device.start()

    for i, device in enumerate(devices):
        device.neighbors = [devices[j].address for j in adjacency[i]]
        for j in adjacency[i]:
            device.connect_to(devices[j].address)

    return devices


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    devices = build_devices(args.devices, args.topology)

    for spec in args.injections:
        time.sleep(spec["delay"])
        msg_id = os.urandom(16)
        devices[spec["device"]].inject(
            payload=spec["payload"],
            ttl=spec["ttl"],
            spray_l=spec["spray_l"],
            zone_id=spec["zone_id"],
            msg_id=msg_id,
        )

    time.sleep(args.wait)

    for device in devices:
        device.transport.stop()


if __name__ == "__main__":
    main()
