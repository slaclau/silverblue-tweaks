export repo_organization := env("GITHUB_REPOSITORY_OWNER", "slaclau")
export image_name := env("IMAGE_NAME", "silverblue-tweaks")
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export SUDO_DISPLAY := if `if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then echo true; fi` == "true" { "true" } else { "false" }
export SUDOIF := if `id -u` == "0" { "" } else if SUDO_DISPLAY == "true" { "sudo" } else { "sudo" }
export PODMAN := if path_exists("/usr/bin/podman") == "true" { env("PODMAN", "/usr/bin/podman") } else if path_exists("/usr/bin/docker") == "true" { env("PODMAN", "docker") } else { env("PODMAN", "exit 1 ; ") }
export SET_X := if `id -u` == "0" { "1" } else { env('SET_X', '') }

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
        echo "Checking syntax: $file"
        just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
        echo "Checking syntax: $file"
        just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    ${SUDOIF} just clean

build $target_image=image_name:
    #!/usr/bin/env bash
    set ${SET_X:+-x} -eou pipefail

    # Get Version
    VERSION="$(date +%Y%m%d)"

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${target_image}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR=${repo_organization}")
    BUILD_ARGS+=("--label" "org.opencontainers.image.version=$VERSION")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    ${PODMAN} build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}" \
        .

rechunk $target_image=image_name:
    #!/usr/bin/env bash
    set ${SET_X:+-x} -eou pipefail
    set -eoux pipefail
    echo "::group:: Rechunk Build Prep"
    if [[ ! {{ PODMAN }} =~ podman ]]; then
        echo "Rechunk only supported with podman. Exiting..."
        exit 0
    fi

    ID=$({{ PODMAN }} images --filter reference=localhost/{{ target_image }} --format "'{{ '{{.ID}}' }}'")

    if [[ -z "$ID" ]]; then
        just build {{ target_image }}
    fi

    if [[ "${UID}" -gt "0" && ! {{ PODMAN }} =~ docker ]]; then
        COPYTMP="$(mktemp -p "${PWD}" -d -t podman_scp.XXXXXXXXXX)"
        {{ SUDOIF }} TMPDIR="${COPYTMP}" {{ PODMAN }} image scp "${UID}"@localhost::localhost/{{ target_image }} root@localhost::localhost/{{ target_image }}
        rm -rf "${COPYTMP}"
    fi


    CREF=$({{ SUDOIF }} {{ PODMAN }} create localhost/{{ target_image }} bash)
    MOUNT=$({{ SUDOIF }} {{ PODMAN }} mount "$CREF")

    OUT_NAME="{{ target_image }}"
    VERSION="$({{ SUDOIF }} {{ PODMAN }} inspect "$CREF" | jq -r '.[]["Config"]["Labels"]["org.opencontainers.image.version"]')"
    LABELS="
    org.opencontainers.image.title={{ target_image }}
    org.opencontainers.image.revision=$(git rev-parse HEAD)
    ostree.linux=$({{ SUDOIF }} {{ PODMAN }} inspect "$CREF" | jq -r '.[].["Config"]["Labels"]["ostree.linux"]')
    org.opencontainers.image.description={{ target_image }} is my OCI image built from ublue projects. It mainly extends them for my uses.
    "
    echo "::endgroup::"

    echo "::group:: Rechunk Prune"
    {{ SUDOIF }} {{ PODMAN }} run --rm \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --env TREE=/var/tree \
        --user 0:0 \
        ghcr.io/hhd-dev/rechunk:latest \
        /sources/rechunk/1_prune.sh
    echo "::endgroup::"

    echo "::group:: Create Tree"
    {{ SUDOIF }} {{ PODMAN }} run --rm \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --volume "cache_ostree:/var/ostree" \
        --env TREE=/var/tree \
        --env REPO=/var/ostree/repo \
        --env RESET_TIMESTAMP=1 \
        --user 0:0 \
        ghcr.io/hhd-dev/rechunk:latest \
        /sources/rechunk/2_create.sh
    {{ SUDOIF }} {{ PODMAN }} unmount "$CREF"
    {{ SUDOIF }} {{ PODMAN }} rm "$CREF"
    if [[ "${UID}" -gt "0" ]]; then
        {{ SUDOIF }} {{ PODMAN }} rmi localhost/{{ target_image }}
    fi
    {{ PODMAN }} rmi localhost/{{ target_image }}
    echo "::endgroup::"

    echo "::group:: Rechunk"
    {{ SUDOIF }} {{ PODMAN }} run --rm \
        --pull=newer \
        --security-opt label=disable \
        --volume "$PWD:/workspace" \
        --volume "$PWD:/var/git" \
        --volume cache_ostree:/var/ostree \
        --env REPO=/var/ostree/repo \
        --env PREV_REF=ghcr.io/{{ repo_organization }}/{{ target_image }} \
        --env LABELS="$LABELS" \
        --env OUT_NAME="$OUT_NAME" \
        --env VERSION="$VERSION" \
        --env VERSION_FN=/workspace/version.txt \
        --env OUT_REF="oci:$OUT_NAME" \
        --env GIT_DIR="/var/git" \
        --user 0:0 \
        ghcr.io/hhd-dev/rechunk:latest \
        /sources/rechunk/3_chunk.sh
    echo "::endgroup::"

    echo "::group:: Cleanup"
    {{ SUDOIF }} find {{ target_image }} -type d -exec chmod 0755 {} \; || true
    {{ SUDOIF }} find {{ target_image }}* -type f -exec chmod 0644 {} \; || true
    if [[ "${UID}" -gt "0" ]]; then
        {{ SUDOIF }} chown -R "${UID}":"${GROUPS[0]}" "${PWD}"
        just load-image {{ target_image }}
    elif [[ "${UID}" == "0" && -n "${SUDO_USER:-}" ]]; then
        {{ SUDOIF }} chown -R "${SUDO_UID}":"${SUDO_GID}" "/run/user/${SUDO_UID}/just"
        {{ SUDOIF }} chown -R "${SUDO_UID}":"${SUDO_GID}" "${PWD}"
    fi

    {{ SUDOIF }} {{ PODMAN }} volume rm cache_ostree
    echo "::endgroup::"

# Load Image into Podman and Tag
[private]
load-image $image=image_name:
    #!/usr/bin/env bash
    set ${SET_X:+-x} -eou pipefail
    IMAGE=$({{ PODMAN }} pull oci:${PWD}/{{ image_name }})
    {{ PODMAN }} tag ${IMAGE} localhost/{{ image_name }}
    VERSION=$({{ PODMAN }} inspect $IMAGE | jq -r '.[]["Config"]["Labels"]["org.opencontainers.image.version"]')
    {{ PODMAN }} tag ${IMAGE} localhost/{{ image_name }}:${VERSION}
    {{ PODMAN }} images
    rm -rf {{ image_name }}

get-tags $image=image_name:
    #!/usr/bin/env bash
    export VERSION="$(date +%Y%m%d)"
    echo "$VERSION"
