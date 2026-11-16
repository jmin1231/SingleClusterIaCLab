"""PKI: the lab's cfssl root CA and every certificate it signs, made once."""

import json
import logging
import os
import shutil
import subprocess

from src.lib.config import CERTS, CFSSL_DIR, LAB_CA, PKI_DIR
from src.lib.system import apt_install, apt_purge

PACKAGES = ["golang-cfssl"]  # cfssl and cfssljson

log = logging.getLogger(__name__)


def up() -> bool:
    """Create the root CA and every missing certificate in state/pki/. Returns True if anything was made."""
    apt_install(PACKAGES)
    PKI_DIR.mkdir(0o755, parents=True, exist_ok=True)
    changed = False

    if not (PKI_DIR / f"{LAB_CA}.pem").exists():
        # A new root: the certificates the old one signed no longer verify, so they are made again below.
        for name in CERTS:
            (PKI_DIR / f"{name}.pem").unlink(missing_ok=True)
        out = subprocess.run(["cfssl", "gencert", "-initca", CFSSL_DIR / f"{LAB_CA}-csr.json"],
                             capture_output=True, text=True, check=True).stdout
        # cfssljson writes ca.pem, ca-key.pem (0600) and ca.csr
        subprocess.run(["cfssljson", "-bare", PKI_DIR / LAB_CA], input=out, text=True, check=True)
        log.info("created root %s", LAB_CA)
        changed = True

    for name, (profile, hosts, (uid, gid)) in CERTS.items():
        cert = PKI_DIR / f"{name}.pem"
        key = PKI_DIR / f"{name}-key.pem"
        # Done = cert and key exist, and the key already has its owner (a crash before chown re-makes it).
        if cert.exists() and key.exists() and key.stat().st_uid == uid:
            continue
        csr = {"CN": hosts[0], "hosts": hosts, "key": {"algo": "ecdsa", "size": 256}}
        out = subprocess.run(["cfssl", "gencert", "-ca", PKI_DIR / f"{LAB_CA}.pem", "-ca-key", PKI_DIR / f"{LAB_CA}-key.pem",
                              "-config", CFSSL_DIR / "ca-config.json", "-profile", profile, "-"],
                             input=json.dumps(csr), capture_output=True, text=True, check=True).stdout
        subprocess.run(["cfssljson", "-bare", PKI_DIR / name], input=out, text=True, check=True)
        os.chown(key, uid, gid)  # the service's container user must be able to read its 0600 key
        log.info("issued %s for %s", name, ", ".join(hosts))
        changed = True

    if not changed:
        log.info("all certificates present in %s", PKI_DIR)
    return changed


def down() -> None:
    """Delete the root CA and every certificate, and remove cfssl."""
    shutil.rmtree(PKI_DIR, ignore_errors=True)
    apt_purge(PACKAGES)
    log.info("PKI removed: %s and cfssl", PKI_DIR)
