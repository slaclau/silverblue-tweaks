#!/bin/python
import json
import pprint
import re
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


def get_tags(manifest):
    tags = manifest["RepoTags"]
    tags = sorted([tag for tag in tags if re.match("[0-9]+", tag)])
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
        if package not in previous_versions:
            added.append(package)
        elif package not in current_versions:
            removed.append(package)
        elif previous_versions[package] != current_versions[package]:
            changed.append(package)
    return {"added": added, "changed": changed, "removed": removed}


def format_changes(changes, curr, prev, header=""):
    out = header + "\n| | Name | Previous | New |\n| --- | --- | --- | --- |"

    for pkg in changes["added"]:
        out += PATTERN_ADD.format(name=pkg, version=curr[pkg])
    for pkg in changes["changed"]:
        out += PATTERN_CHANGE.format(name=pkg, prev=prev[pkg], new=curr[pkg])
    for pkg in changes["removed"]:
        out += PATTERN_REMOVE.format(name=pkg, version=prev[pkg])
    return out


def get_changes(image):
    manifest = get_manifest(image)
    previous, current = get_tags(manifest)
    current_manifest = get_manifest(f"{image}:{current}")
    previous_manifest = get_manifest(f"{image}:{previous}")

    versions = get_versions(current_manifest)
    previous_versions = get_versions(previous_manifest)

    changes = calculate_changes(versions, previous_versions)
    header = f"""#{image} ({current})
There have been the following changes since previous version ({previous}):"""

    out = format_changes(changes, versions, previous_versions, header)
    return out

with open("changelog.md", "w") as f:
    f.write(get_changes("silverblue-tweaks"))
