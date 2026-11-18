"""Podman settings: packages, the home:alvistack apt repository and the API socket."""

from pathlib import Path

FILES = Path(__file__).parents[1] / "files"

# --- Packages ---
PACKAGES = ["podman", "podman-netavark", "podman-aardvark-dns", "docker-compose-v2", "uidmap"]
# Pulled in from home:alvistack by podman 6; purged on destroy together with PACKAGES
DEPENDENCIES = ["buildah", "skopeo", "conmon", "crun", "containers-common", "containers-storage",
                "catatonit", "containernetworking", "containernetworking-plugins", "passt"]

# --- Apt repository (home:alvistack, pinned to the Podman stack only) ---
KEY_URL = "https://downloadcontent.opensuse.org/repositories/home:/alvistack/xUbuntu_24.04/Release.key"
KEYRING = Path("/etc/apt/keyrings/alvistack.asc")
SOURCE = Path("/etc/apt/sources.list.d/lab-alvistack.list")
PIN = Path("/etc/apt/preferences.d/lab-alvistack")

# --- API socket Compose talks to ---
SOCKET = "podman.socket"
