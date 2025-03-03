#!/bin/python
import json
import pprint
import re
import sys
import subprocess
import time

REGISTRY = "docker://ghcr.io"
NAMESPACE = "slaclau"

RETRIES = 3
RETRY_WAIT = 5

FEDORA_PATTERN = re.compile(r"\.fc\d\d")

PATTERN_ADD = "\n| ✨ | {name} | | {version} |"
PATTERN_CHANGE = "\n| 🔄 | {name} | {prev} | {new} |"
PATTERN_REMOVE = "\n| ❌ | {name} | {version} | |"

IMPORTANT_PACKAGES = {
    "kernel": "Kernel",
    "mesa-dri-drivers": "Mesa",
    "podman": "Podman",
    "gnome-control-center-filesystem": "GNOME",
    "nvidia-driver": "Nvidia",
    "plasma-desktop": "KDE",
    "docker-ce": "Docker",
    "incus": "Incus",
}

IGNORE_PACKAGES = [
    "kernel",
    "mesa-dri-drivers",
    "podman",
    "nvidia-driver",
    "docker-ce",
    "incus"
]

def get_manifest(image):
    output = None
    print(f"Getting {image} manifest")
    for i in range(RETRIES):
        try:
            output = subprocess.run(
                ["skopeo", "inspect", REGISTRY + "/" + NAMESPACE + "/" + image],
                check=True,
                stdout=subprocess.PIPE,
            ).stdout
            break
        except subprocess.CalledProcessError:
            print(
                f"Failed to get {image}, retrying in {RETRY_WAIT} seconds ({i+1}/{RETRIES})"
            )
            time.sleep(RETRY_WAIT)
    return json.loads(output)

def get_tags(manifest, stream):
    tags = manifest["RepoTags"]
    tags = sorted([tag for tag in tags if re.match(f"{stream}-[0-9]+", tag)])
    return tags[-2], tags[-1]


def get_packages(manifest):
    return json.loads(manifest["Labels"]["dev.hhd.rechunk.info"])["packages"]


def get_versions(manifest):
    packages = get_packages(manifest)
    return {
        package: re.sub(FEDORA_PATTERN, "", version)
        for package, version in packages.items()
    }


def calculate_changes(
    current_versions: dict[str, str],
    previous_versions: dict[str, str],
    packages: list[str] | None = None,
):
    added = []
    changed = []
    removed = []

    if packages is None:
        packages = set(list(current_versions.keys()) + list(previous_versions.keys()))

    for package in packages:
        if package in IGNORE_PACKAGES:
            continue
        if package not in previous_versions:
            added.append(package)
        elif package not in current_versions:
            removed.append(package)
        elif previous_versions[package] != current_versions[package]:
            changed.append(package)
    return {"added": added, "changed": changed, "removed": removed}


def format_changes(changes, curr, prev, header=""):
    out = header

    out = out + "\n## Major packages\n| Name | Version |\n| --- | --- |"

    for pkg, ver in curr.items():
        if pkg not in IMPORTANT_PACKAGES:
            continue
        if pkg not in prev or prev[pkg] == ver:
            out = out + f"\n| {IMPORTANT_PACKAGES[pkg]} | {ver} |"
        else:
            out = out + f"\n| {IMPORTANT_PACKAGES[pkg]} | {prev[pkg]} ➡️ {ver}"
    if changes["added"] or changes["changed"] or changes["removed"]:
        out = out + "\n## Packages\n| | Name | Previous | New |\n| --- | --- | --- | --- |"

    for pkg in changes["added"]:
        out += PATTERN_ADD.format(name=pkg, version=curr[pkg])
    for pkg in changes["changed"]:
        out += PATTERN_CHANGE.format(name=pkg, prev=prev[pkg], new=curr[pkg])
    for pkg in changes["removed"]:
        out += PATTERN_REMOVE.format(name=pkg, version=prev[pkg])
    return out

def calculate_layers(manifest, previous_manifest):
    layers = manifest["LayersData"]
    previous_layers = previous_manifest["LayersData"]
    indexes = [layers.index(layer) if layer in layers else None for layer in previous_layers]

    for i in range(0, len(indexes)):
        idx = indexes[i]

def get_changes(image, stream):
    manifest = get_manifest(f"{image}:{stream}")
    previous, current = get_tags(manifest, stream)
    current_manifest = get_manifest(f"{image}:{current}")
    previous_manifest = get_manifest(f"{image}:{previous}")

    versions = get_versions(current_manifest)
    previous_versions = get_versions(previous_manifest)

    changes = calculate_changes(versions, previous_versions)
    layers = calculate_layers(current_manifest, previous_manifest)

    header = f"""# {image} ({current})
There have been the following changes since previous version ({previous}):"""

    out = format_changes(changes, versions, previous_versions, header)
    return out, current

if __name__ == "__main__":
    changes, tag = get_changes(sys.argv[1], sys.argv[2])
    with open("changelog.md", "w") as f:
        f.write(changes)
    with open("changelog.env", "w") as f:
        f.write(f"TAG={tag}")
