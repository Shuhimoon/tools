#!/usr/bin/env python3
"""OCI Always Free camper — one cycle.

Targets (Singapore home region only, free resources only):
  - af-amd-50   VM.Standard.E2.1.Micro boot 50GB
  - af-amd-100  VM.Standard.E2.1.Micro boot 100GB
  - af-arm-2o12 VM.Standard.A1.Flex 2 OCPU / 12GB boot 50GB

Auth: OCI CLI config (~/.oci/config). No keys are embedded in this script.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

REGION = os.environ.get("OCI_REGION", "ap-singapore-1")
PROFILE = os.environ.get("OCI_CLI_PROFILE", "DEFAULT")
COMPARTMENT = os.environ["OCI_COMPARTMENT_ID"]
SUBNET = os.environ["OCI_SUBNET_ID"]
AD = os.environ.get("OCI_AVAILABILITY_DOMAIN", "")
SSH_PUB = Path(os.path.expanduser(os.environ.get("SSH_PUBLIC_KEY_FILE", "~/.ssh/oci_always_free.pub")))

FLEET = [
    {
        "name": "af-amd-50",
        "shape": "VM.Standard.E2.1.Micro",
        "boot_gb": 50,
        "ocpus": None,
        "memory_gb": None,
        "arch": "x86",
    },
    {
        "name": "af-amd-100",
        "shape": "VM.Standard.E2.1.Micro",
        "boot_gb": 100,
        "ocpus": None,
        "memory_gb": None,
        "arch": "x86",
    },
    {
        "name": "af-arm-2o12",
        "shape": "VM.Standard.A1.Flex",
        "boot_gb": 50,
        "ocpus": 2,
        "memory_gb": 12,
        "arch": "aarch64",
    },
]


def load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def oci(args: list[str], check: bool = False) -> subprocess.CompletedProcess:
    cmd = ["oci", *args, "--region", REGION, "--profile", PROFILE, "--output", "json"]
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def oci_json(args: list[str]):
    p = oci(args)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or f"oci failed: {args}")
    return json.loads(p.stdout) if p.stdout.strip() else {}


def list_instances() -> list[dict]:
    data = oci_json(
        [
            "compute",
            "instance",
            "list",
            "--compartment-id",
            COMPARTMENT,
            "--lifecycle-state",
            "RUNNING",
            "--all",
        ]
    ).get("data", [])
    # also include PROVISIONING
    data2 = oci_json(
        [
            "compute",
            "instance",
            "list",
            "--compartment-id",
            COMPARTMENT,
            "--lifecycle-state",
            "PROVISIONING",
            "--all",
        ]
    ).get("data", [])
    return list(data) + list(data2)


def find_ubuntu_image(arch: str) -> str:
    env_key = "OCI_IMAGE_AMD" if arch == "x86" else "OCI_IMAGE_ARM"
    pinned = os.environ.get(env_key, "").strip()
    if pinned:
        return pinned
    # Platform images; prefer Ubuntu 24.04 Minimal free
    operating_system = "Canonical Ubuntu"
    # list images then filter client-side for Minimal 24.04
    raw = oci_json(
        [
            "compute",
            "image",
            "list",
            "--compartment-id",
            COMPARTMENT,
            "--operating-system",
            operating_system,
            "--operating-system-version",
            "24.04",
            "--shape",
            "VM.Standard.E2.1.Micro" if arch == "x86" else "VM.Standard.A1.Flex",
            "--sort-by",
            "TIMECREATED",
            "--sort-order",
            "DESC",
            "--all",
        ]
    ).get("data", [])
    prefer = []
    for img in raw:
        name = (img.get("display-name") or "")
        if "Minimal" in name and "24.04" in name:
            if arch == "aarch64" and "aarch64" in name.lower():
                prefer.append(img)
            elif arch == "x86" and "aarch64" not in name.lower():
                prefer.append(img)
    if not prefer:
        prefer = [
            img
            for img in raw
            if "24.04" in (img.get("display-name") or "")
            and (("aarch64" in (img.get("display-name") or "").lower()) == (arch == "aarch64"))
        ]
    if not prefer:
        raise RuntimeError(f"No free Ubuntu 24.04 image found for arch={arch}")
    return prefer[0]["id"]


def resolve_ad() -> str:
    global AD
    if AD:
        return AD
    ads = oci_json(
        ["iam", "availability-domain", "list", "--compartment-id", COMPARTMENT]
    ).get("data", [])
    if not ads:
        raise RuntimeError("No availability domain found")
    AD = ads[0]["name"]
    return AD


def create_instance(spec: dict) -> tuple[bool, str]:
    if not SSH_PUB.is_file():
        return False, f"SSH public key missing: {SSH_PUB}"
    ssh = SSH_PUB.read_text().strip()
    image_id = find_ubuntu_image(spec["arch"])
    ad = resolve_ad()
    args = [
        "compute",
        "instance",
        "launch",
        "--compartment-id",
        COMPARTMENT,
        "--availability-domain",
        ad,
        "--display-name",
        spec["name"],
        "--shape",
        spec["shape"],
        "--subnet-id",
        SUBNET,
        "--image-id",
        image_id,
        "--assign-public-ip",
        "true",
        "--ssh-authorized-keys-file",
        str(SSH_PUB),
        "--boot-volume-size-in-gbs",
        str(spec["boot_gb"]),
        "--wait-for-state",
        "RUNNING",
        "--wait-for-state",
        "TERMINATED",
        "--max-wait-seconds",
        "120",
    ]
    # flex shape config
    if spec["ocpus"] is not None:
        shape_config = json.dumps(
            {"ocpus": spec["ocpus"], "memoryInGBs": spec["memory_gb"]}
        )
        args.extend(["--shape-config", shape_config])
    p = oci(args)
    out = (p.stderr or "") + "\n" + (p.stdout or "")
    if p.returncode == 0:
        return True, "created/running"
    # classify common camp errors
    low = out.lower()
    if "out of host capacity" in low or "out of capacity" in low:
        return False, "Out of host capacity"
    if "too many requests" in low or "429" in out:
        return False, "TooManyRequests (429)"
    return False, out.strip().splitlines()[-1][:300] if out.strip() else "create failed"


def main() -> int:
    root = Path(__file__).resolve().parent
    load_dotenv(root / ".env")

    required = ["OCI_COMPARTMENT_ID", "OCI_SUBNET_ID"]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        print(f"Missing env: {', '.join(missing)}. Copy .env.example to .env", file=sys.stderr)
        return 2

    try:
        instances = list_instances()
    except Exception as e:
        print(f"AUTH/LIST failed: {e}", file=sys.stderr)
        return 1

    by_name = {i.get("display-name"): i for i in instances}
    print(f"region={REGION}")
    successes = []
    for spec in FLEET:
        name = spec["name"]
        cur = by_name.get(name)
        if cur and cur.get("lifecycle-state") in ("RUNNING", "PROVISIONING"):
            print(f"{name}: already {cur.get('lifecycle-state')} (skip)")
            continue
        print(f"{name}: missing — trying create…")
        ok, msg = create_instance(spec)
        print(f"{name}: {'OK' if ok else 'FAIL'} — {msg}")
        if ok:
            successes.append(name)
        # brief pause between creates to reduce 429s
        time.sleep(2)

    if successes:
        print("NOTIFY: created " + ", ".join(successes))
        return 0
    print("quiet: no new success")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
