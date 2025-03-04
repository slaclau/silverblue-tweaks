ARG IMAGE_NAME="${IMAGE_NAME:-silverblue}"
ARG BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-silverblue}"
ARG SOURCE_ORG="${SOURCE_ORG:-fedora-ostree-desktops}"
ARG BASE_IMAGE="quay.io/${SOURCE_ORG}/${BASE_IMAGE_NAME}"

ARG FEDORA_MAJOR_VERSION="${FEDORA_MAJOR_VERSION:-41}"

FROM scratch AS ctx
COPY / /

FROM ${BASE_IMAGE}:${FEDORA_MAJOR_VERSION} as base

ARG IMAGE_NAME="${IMAGE_NAME:-silverblue}"
ARG FEDORA_MAJOR_VERSION="${FEDORA_MAJOR_VERSION:-41}"
ARG KERNEL="${KERNEL}"

RUN --mount=type=bind,from=ctx,src=/,dst=/ctx \
    /ctx/build.sh
