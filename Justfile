export repo_organization := env("GITHUB_REPOSITORY_OWNER", "slaclau")
export image_name := env("IMAGE_NAME", "silverblue-tweaks")
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
export SUDO_DISPLAY := if `if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then echo true; fi` == "true" { "true" } else { "false" }
export SUDOIF := if `id -u` == "0" { "" } else if SUDO_DISPLAY == "true" { "sudo" } else { "sudo" }
export PODMAN := if path_exists("/usr/bin/podman") == "true" { env("PODMAN", "/usr/bin/podman") } else if path_exists("/usr/bin/docker") == "true" { env("PODMAN", "docker") } else { env("PODMAN", "exit 1 ; ") }
export SET_X := if `id -u` == "0" { "1" } else { env('SET_X', '') }
export PULL_POLICY := if PODMAN =~ "docker" { "missing" } else { "newer" }

images := '(
    [silverblue-tweaks]=silverblue-tweaks
)'
flavors := '(
    [main]=main
)'
tags := '(
    [gts]=gts
    [stable]=stable
    [latest]=latest
    [beta]=beta
)'

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

# Check if valid combo
[group('Utility')]
[private]
validate $image $tag $flavor:
    #!/usr/bin/bash
    set -eou pipefail
    declare -A images={{ images }}
    declare -A tags={{ tags }}
    declare -A flavors={{ flavors }}

    # Handle Stable Daily
    if [[ "${tag}" == "stable-daily" ]]; then
        tag="stable"
    fi

    checkimage="${images[${image}]-}"
    checktag="${tags[${tag}]-}"
    checkflavor="${flavors[${flavor}]-}"

    # Validity Checks
    if [[ -z "$checkimage" ]]; then
        echo "Invalid Image..."
        exit 1
    fi
    if [[ -z "$checktag" ]]; then
        echo "Invalid tag..."
        exit 1
    fi
    if [[ -z "$checkflavor" ]]; then
        echo "Invalid flavor..."
        exit 1
    fi
    if [[ ! "$checktag" =~ latest && "$checkflavor" =~ hwe|asus|surface ]]; then
        echo "HWE images are only built on latest..."
        exit 1
    fi

# Build Image
[group('Image')]
build $image=image_name $tag="latest" $flavor="main" ghcr="0" pipeline="0" $kernel_pin="":
    #!/usr/bin/bash

    echo "::group:: Build Prep"
    set ${SET_X:+-x} -eou pipefail

    # Validate
    just validate "${image}" "${tag}" "${flavor}"

    # Image Name
    image_name=$(just image_name {{ image }} {{ tag }} {{ flavor }})

    # Base Image
    base_image_name=$(just base_image_name {{ image }} {{ tag }} {{ flavor }})

    # Target
    target="base"

    # Fedora Version
    if [[ {{ ghcr }} == "0" ]]; then
        rm -f /tmp/manifest.json
    fi
    fedora_version=$(just fedora_version '{{ image }}' '{{ tag }}' '{{ flavor }}' '{{ kernel_pin }}')

    # Verify Base Image with cosign
    just verify-container "${base_image_name}:${fedora_version}" "quay.io/fedora-ostree-desktops"  "https://gitlab.com/fedora/ostree/ci-test/-/raw/main/quay.io-fedora-ostree-desktops.pub?ref_type=heads"

    # Kernel Release/Pin
    if [[ -z "${kernel_pin:-}" ]]; then
        kernel_release=$(skopeo inspect --retry-times 3 docker://ghcr.io/ublue-os/akmods:main-"${fedora_version}" | jq -r '.Labels["ostree.linux"]')
    else
        kernel_release="${kernel_pin}"
    fi

    # Get Version
    if [[ "${tag}" =~ stable ]]; then
        ver="${fedora_version}.$(date +%Y%m%d)"
    else
        ver="${tag}-${fedora_version}.$(date +%Y%m%d)"
    fi
    skopeo list-tags docker://ghcr.io/{{ repo_organization }}/${image_name} > /tmp/repotags.json
    if [[ $(jq "any(.Tags[]; contains(\"$ver\"))" < /tmp/repotags.json) == "true" ]]; then
        POINT="1"
        while $(jq -e "any(.Tags[]; contains(\"$ver.$POINT\"))" < /tmp/repotags.json)
        do
            (( POINT++ ))
        done
    fi
    if [[ -n "${POINT:-}" ]]; then
        ver="${ver}.$POINT"
    fi

    # Build Arguments
    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "BASE_IMAGE_NAME=${base_image_name}")
    BUILD_ARGS+=("--build-arg" "FEDORA_MAJOR_VERSION=${fedora_version}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${image_name}")
    BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR={{ repo_organization }}")
    BUILD_ARGS+=("--build-arg" "KERNEL=${kernel_release}")
    BUILD_ARGS+=("--build-arg" "VERSION=${ver}")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi
    BUILD_ARGS+=("--build-arg" "STREAM=${tag}")
    if [[ "${PODMAN}" =~ docker && "${TERM}" == "dumb" ]]; then
        BUILD_ARGS+=("--progress" "plain")
    fi

    # Labels
    LABELS=$(just generate_labels ${image_name} ${kernel_release} | jq .[])
    LABELS+="\norg.opencontainers.image.version=${ver}"

    LABEL_ARGS=()
    IFS=$'\n'
    for label in $LABELS; do
        if [ -z "$label" ]; then
            continue
        fi
        LABEL_ARGS+=("--label" "$label")
    done
    unset IFS

    echo "::endgroup::"
    echo "::group:: Build Container"

    # Build Image
    ${PODMAN} build \
        "${BUILD_ARGS[@]}" \
        "${LABEL_ARGS[@]}" \
        --target "${target}" \
        --tag localhost/"${image_name}:${tag}" \
        --file Containerfile \
        .
    echo "::endgroup::"

[group('Image')]
rechunk $image="bluefin" $tag="latest" $flavor="main" ghcr="0" pipeline="0":
    #!/usr/bin/env bash
    set ${SET_X:+-x} -eou pipefail
    set -eoux pipefail
    echo "::group:: Rechunk Build Prep"
    if [[ ! {{ PODMAN }} =~ podman ]]; then
        echo "Rechunk only supported with podman. Exiting..."
        exit 0
    fi

    # Validate
    just validate "${image}" "${tag}" "${flavor}"

    # Image Name
    image_name=$(just image_name {{ image }} {{ tag }} {{ flavor }})

    # Check if image is already built
    ID=$(${PODMAN} images --filter reference=localhost/"${image_name}":"${tag}" --format "'{{ '{{.ID}}' }}'")
    if [[ -z "$ID" ]]; then
        just build "${image}" "${tag}" "${flavor}"
    fi

    # Load into Rootful Podman
    ID=$(${SUDOIF} ${PODMAN} images --filter reference=localhost/"${image_name}":"${tag}" --format "'{{ '{{.ID}}' }}'")
    if [[ -z "$ID" && "${UID}" -gt "0" && ! {{ PODMAN }} =~ docker ]]; then
        COPYTMP="$(mktemp -p "${PWD}" -d -t podman_scp.XXXXXXXXXX)"
        ${SUDOIF} TMPDIR=${COPYTMP} ${PODMAN} image scp ${UID}@localhost::localhost/"${image_name}":"${tag}" root@localhost::localhost/"${image_name}":"${tag}"
        rm -rf "${COPYTMP}"
    fi

    # Prep Container
    CREF=$(${SUDOIF} ${PODMAN} create localhost/"${image_name}":"${tag}" bash)
    OLD_IMAGE=$(${SUDOIF} ${PODMAN} inspect $CREF | jq -r '.[].Image')
    OUT_NAME="${image_name}"
    MOUNT=$(${SUDOIF} ${PODMAN} mount "${CREF}")

    # Label Version
    VERSION=$(${SUDOIF} ${PODMAN} inspect $CREF | jq -r '.[].Config.Labels["org.opencontainers.image.version"]')
    # Git SHA
    SHA=""
    if [[ -z "$(git status -s)" ]]; then
        SHA=$(git rev-parse HEAD)
    fi
    LABELS=$(just generate_labels ${image_name} $({{ SUDOIF }} {{ PODMAN }} inspect "$CREF" | jq -r '.[].["Config"]["Labels"]["ostree.linux"]'))

    echo "::endgroup::"
    # Rechunk Container
    rechunker="ghcr.io/hhd-dev/rechunk:v1.1.3"

    echo "::group:: Rechunk Prune"
    # Run Rechunker's Prune
    ${SUDOIF} ${PODMAN} run --rm \
        --pull=${PULL_POLICY} \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --env TREE=/var/tree \
        --user 0:0 \
        "${rechunker}" \
        /sources/rechunk/1_prune.sh
    echo "::endgroup::"

    echo "::group:: Create ostree tree"
    # Run Rechunker's Create
    ${SUDOIF} ${PODMAN} run --rm \
        --security-opt label=disable \
        --volume "$MOUNT":/var/tree \
        --volume "cache_ostree:/var/ostree" \
        --env TREE=/var/tree \
        --env REPO=/var/ostree/repo \
        --env RESET_TIMESTAMP=1 \
        --user 0:0 \
        "${rechunker}" \
        /sources/rechunk/2_create.sh

    # Cleanup Temp Container Reference
    ${SUDOIF} ${PODMAN} unmount "$CREF"
    ${SUDOIF} ${PODMAN} rm "$CREF"
    ${SUDOIF} ${PODMAN} rmi "$OLD_IMAGE"
    echo "::endgroup::"

    echo "::group:: Rechunk Chunk"
    # Run Rechunker
    ${SUDOIF} ${PODMAN} run --rm \
        --pull=${PULL_POLICY} \
        --security-opt label=disable \
        --volume "$PWD:/workspace" \
        --volume "$PWD:/var/git" \
        --volume cache_ostree:/var/ostree \
        --env REPO=/var/ostree/repo \
        --env PREV_REF=ghcr.io/ublue-os/"${image_name}":"${tag}" \
        --env OUT_NAME="$OUT_NAME" \
        --env LABELS="${LABELS}" \
        --env "DESCRIPTION='An interpretation of the Ubuntu spirit built on Fedora technology'" \
        --env "VERSION=${VERSION}" \
        --env VERSION_FN=/workspace/version.txt \
        --env OUT_REF="oci:$OUT_NAME" \
        --env GIT_DIR="/var/git" \
        --env REVISION="$SHA" \
        --user 0:0 \
        "${rechunker}" \
        /sources/rechunk/3_chunk.sh

    # Fix Permissions of OCI
    ${SUDOIF} find ${OUT_NAME} -type d -exec chmod 0755 {} \; || true
    ${SUDOIF} find ${OUT_NAME}* -type f -exec chmod 0644 {} \; || true

    if [[ "${UID}" -gt "0" ]]; then
        ${SUDOIF} chown "${UID}:${GROUPS}" -R "${PWD}"
    elif [[ -n "${SUDO_UID:-}" ]]; then
        chown "${SUDO_UID}":"${SUDO_GID}" -R "${PWD}"
    fi
    echo "::endgroup::"

    echo "::group:: Cleanup"
    # Remove cache_ostree
    ${SUDOIF} ${PODMAN} volume rm cache_ostree

    echo "::endgroup::"

    # Pipeline Checks
    if [[ {{ pipeline }} == "1" && -n "${SUDO_USER:-}" ]]; then
        sudo -u "${SUDO_USER}" just load-rechunk "${image}" "${tag}" "${flavor}"
        sudo -u "${SUDO_USER}" just secureboot "${image}" "${tag}" "${flavor}"
    fi
    echo "::endgroup::"

# Load Image into Podman and Tag
[private]
load-image $image $tag $flavor:
    #!/usr/bin/env bash
    set ${SET_X:+-x} -eou pipefail
    image_name=$(just image_name {{ image }} {{ tag }} {{ flavor }})
    IMAGE=$({{ PODMAN }} pull oci:${PWD}/{{ image_name }})
    ${PODMAN} tag ${IMAGE} localhost/"${image_name}":{{ tag }}

    rm -rf ${image_name}*
    rm -f previous.manifest.json

# Verify Container with Cosign
[group('Utility')]
verify-container container="" registry="ghcr.io/slaclau" key="":
    #!/usr/bin/bash
    set -eou pipefail

    # Get Cosign if Needed
    if [[ ! $(command -v cosign) ]]; then
        COSIGN_CONTAINER_ID=$(${SUDOIF} ${PODMAN} create cgr.dev/chainguard/cosign:latest bash)
        ${SUDOIF} ${PODMAN} cp "${COSIGN_CONTAINER_ID}":/usr/bin/cosign /usr/local/bin/cosign
        ${SUDOIF} ${PODMAN} rm -f "${COSIGN_CONTAINER_ID}"
    fi

    # Verify Cosign Image Signatures if needed
    if [[ -n "${COSIGN_CONTAINER_ID:-}" ]]; then
        if ! cosign verify --certificate-oidc-issuer=https://token.actions.githubusercontent.com --certificate-identity=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main cgr.dev/chainguard/cosign >/dev/null; then
            echo "NOTICE: Failed to verify cosign image signatures."
            exit 1
        fi
    fi

    # Public Key for Container Verification
    key={{ key }}
    if [[ -z "${key:-}" ]]; then
        key="https://raw.githubusercontent.com/slaclau/silverblue-tweaks/main/cosign.pub"
    fi

    # Verify Container using cosign public key
    if ! cosign verify --key "${key}" "{{ registry }}"/"{{ container }}" >/dev/null; then
        echo "NOTICE: Verification failed. Please ensure your public key is correct."
        exit 1
    fi

# Get Fedora Version of an image
[group('Utility')]
[private]
fedora_version image=image_name tag=default_tag flavor="main" $kernel_pin="":
    #!/usr/bin/bash
    set -eou pipefail
    just validate {{ image }} {{ tag }} {{ flavor }}
    if [[ ! -f /tmp/manifest.json ]]; then
        if [[ "{{ tag }}" =~ stable ]]; then
            # CoreOS does not uses cosign
            skopeo inspect --retry-times 3 docker://quay.io/fedora/fedora-coreos:stable > /tmp/manifest.json
        else
            skopeo inspect --retry-times 3 docker://ghcr.io/ublue-os/base-main:"{{ tag }}" > /tmp/manifest.json
        fi
    fi
    fedora_version=$(jq -r '.Labels["ostree.linux"]' < /tmp/manifest.json | grep -oP 'fc\K[0-9]+')
    if [[ -n "${kernel_pin:-}" ]]; then
        fedora_version=$(echo "${kernel_pin}" | grep -oP 'fc\K[0-9]+')
    fi
    echo "${fedora_version}"

# Image Name
[group('Utility')]
[private]
image_name $image=image_name $tag=default_tag $flavor="main":
    #!/usr/bin/bash
    set -eou pipefail
    just validate {{ image }} {{ tag }} {{ flavor }}
    if [[ "{{ flavor }}" =~ main ]]; then
        image_name={{ image }}
    else
        image_name="{{ image }}-{{ flavor }}"
    fi
    echo "${image_name}"

# Base Image Name
[group('Utility')]
[private]
base_image_name $image=image_name $tag=default_tag $flavor="main":
    #!/usr/bin/bash
    set -eou pipefail
    just validate {{ image }} {{ tag }} {{ flavor }}
    base_image_name=silverblue

    echo ${base_image_name}

# Generate Tags
[group('Utility')]
generate-build-tags $image=image_name $tag=default_tag flavor="main" kernel_pin="" ghcr="0" $version="" github_event="" github_number="":
    #!/usr/bin/env bash
    set -eou pipefail

    TODAY="$(date +%A)"
    WEEKLY="Sunday"
    if [[ {{ ghcr }} == "0" ]]; then
        rm -f /tmp/manifest.json
    fi
    FEDORA_VERSION="$(just fedora_version '{{ image }}' '{{ tag }}' '{{ flavor }}' '{{ kernel_pin }}')"
    DEFAULT_TAG=$(just generate-default-tag {{ tag }} {{ ghcr }})
    IMAGE_NAME=$(just image_name {{ image }} {{ tag }} {{ flavor }})
    # Use Build Version from Rechunk
    if [[ -z "${version:-}" ]]; then
        version="{{ tag }}-${FEDORA_VERSION}.$(date +%Y%m%d)"
    fi
    version=${version#{{ tag }}-}

    # Arrays for Tags
    BUILD_TAGS=()
    COMMIT_TAGS=()

    # Commit Tags
    github_number="{{ github_number }}"
    SHA_SHORT="$(git rev-parse --short HEAD)"
    if [[ "{{ ghcr }}" == "1" ]]; then
        COMMIT_TAGS+=(pr-${github_number:-}-{{ tag }}-${version})
        COMMIT_TAGS+=(${SHA_SHORT}-{{ tag }}-${version})
    fi

    # Convenience Tags
    if [[ "{{ tag }}" =~ stable ]]; then
        BUILD_TAGS+=("stable-daily" "${version}" "stable-daily-${version}" "stable-daily-${version:3}")
    else
        BUILD_TAGS+=("{{ tag }}" "{{ tag }}-${version}" "{{ tag }}-${version:3}")
    fi

    # Weekly Stable / Rebuild Stable on workflow_dispatch
    github_event="{{ github_event }}"
    if [[ "{{ tag }}" =~ "stable" && "${WEEKLY}" == "${TODAY}" && "${github_event}" =~ schedule ]]; then
        BUILD_TAGS+=("stable" "stable-${version}" "stable-${version:3}")
    elif [[ "{{ tag }}" =~ "stable" && "${github_event}" =~ workflow_dispatch|workflow_call ]]; then
        BUILD_TAGS+=("stable" "stable-${version}" "stable-${version:3}")
    elif [[ "{{ tag }}" =~ "stable" && "{{ ghcr }}" == "0" ]]; then
        BUILD_TAGS+=("stable" "stable-${version}" "stable-${version:3}")
    elif [[ ! "{{ tag }}" =~ stable|beta ]]; then
        BUILD_TAGS+=("${FEDORA_VERSION}" "${FEDORA_VERSION}-${version}" "${FEDORA_VERSION}-${version:3}")
    fi

    if [[ "${github_event}" == "pull_request" ]]; then
        alias_tags=("${COMMIT_TAGS[@]}")
    else
        alias_tags=("${BUILD_TAGS[@]}")
    fi

    echo "${alias_tags[*]}"

# Generate Default Tag
[group('Utility')]
generate-default-tag tag="latest" ghcr="0":
    #!/usr/bin/bash
    set -eou pipefail

    # Default Tag
    if [[ "{{ tag }}" =~ stable && "{{ ghcr }}" == "1" ]]; then
        DEFAULT_TAG="stable-daily"
    elif [[ "{{ tag }}" =~ stable && "{{ ghcr }}" == "0" ]]; then
        DEFAULT_TAG="stable"
    else
        DEFAULT_TAG="{{ tag }}"
    fi

    echo "${DEFAULT_TAG}"

# Generate Labels
[group('Utility')]
generate_labels $image=image_name $kernel_release="":
    #!/usr/bin/bash
    set -eou pipefail

    LABELS=()
    LABELS+=("org.opencontainers.image.title=${image}")
    if [[ -n $kernel_release ]]; then
        LABELS+=("ostree.linux=${kernel_release}")
    fi
    LABELS+=("io.artifacthub.package.readme-url=https://raw.githubusercontent.com/slaclau/silverblue-tweaks/refs/heads/main/README.md")
    LABELS+=("io.artifacthub.package.logo-url=https://avatars.githubusercontent.com/u/77557628?s=200&v=4")
    LABELS+=("containers.bootc=1")
    LABELS+=("org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
    LABELS+=("org.opencontainers.image.source=https://raw.githubusercontent.com/slaclau/silverblue-tweaks/refs/heads/main/Containerfile")
    LABELS+=("org.opencontainers.image.vendor={{ repo_organization }}")
    LABELS+=("io.artifacthub.package.deprecated=false")
    LABELS+=("io.artifacthub.package.keywords=bootc,fedora")
    LABELS+=("io.artifacthub.package.maintainers=[{\"name\": \"Sebastien Laclau\", \"email\": \"seb.laclau@gmail.com\"}]")
    jq -c -n '$ARGS.positional' --args "${LABELS[@]}"

# Tag Images
[group('Utility')]
tag-images image_name="" default_tag="" tags="":
    #!/usr/bin/bash
    set -eou pipefail

    # Get Image, and untag
    IMAGE=$(${PODMAN} inspect localhost/{{ image_name }}:{{ default_tag }} | jq -r .[].Id)
    ${PODMAN} untag localhost/{{ image_name }}:{{ default_tag }}

    # Tag Image
    for tag in {{ tags }}; do
        ${PODMAN} tag $IMAGE {{ image_name }}:${tag}
    done

    # HWE Tagging
    if [[ "{{ image_name }}" =~ hwe ]]; then

        image_name="{{ image_name }}"
        asus_name="${image_name/hwe/asus}"
        surface_name="${image_name/hwe/surface}"

        for tag in {{ tags }}; do
            ${PODMAN} tag "${IMAGE}" "${asus_name}":${tag}
            ${PODMAN} tag "${IMAGE}" "${surface_name}":${tag}
        done
    fi

    # Show Images
    ${PODMAN} images
