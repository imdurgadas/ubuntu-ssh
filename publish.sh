#!/bin/bash -eu

set -eou pipefail

ARCHS=(arm arm64 s390x amd64 ppc64le)
QEMUARCHS=(arm aarch64 s390x x86_64 ppc64le)
QEMUVER="v2.12.0-1"
REGISTRY="durgadas"
IMAGE="ubuntu-ssh"
BASEIMAGE=

get-manifest-tool() {
    if [[ ! -f manifest-tool ]]; then
        local version
        version=$(curl -s https://api.github.com/repos/estesp/manifest-tool/tags | jq -r '.[0].name')

        echo "Downloading manifest-tool"
        if ! curl -OLs "https://github.com/estesp/manifest-tool/releases/download/$version/manifest-tool-linux-amd64"; then
            echo "Error downloading manifest-tool"
            exit
        fi

        mv manifest-tool-linux-amd64 manifest-tool
        chmod +x manifest-tool
    fi
}

get-qemu() {
    if [[ ! $(find . -name "*qemu-*") ]]; then
        echo "Downloading Qemu "
        for target_arch in ${QEMUARCHS[*]}; do
            if ! curl -OLs "https://github.com/multiarch/qemu-user-static/releases/download/$QEMUVER/x86_64_qemu-${target_arch}-static.tar.gz"; then
                echo "Error downloading Qemu"
                exit
            fi
            tar -xvf x86_64_qemu-"${target_arch}"-static.tar.gz
        done
        rm -f x86_64_qemu-*
    fi
}

makeDockerfile() {
    local arch=$1
    local dockerfile

    dockerfile="Dockerfile-${arch}"

    /bin/cp -f Dockerfile.template "$dockerfile"

    # Make the Dockerfile after we set the base image
    sed -i "s|BASEIMAGE|${BASEIMAGE}|g" "$dockerfile"

    if [[ "${arch}" == "amd64" ]]; then
        sed -i "/CROSS_BUILD_/d" "$dockerfile"
    else
        if [[ "${arch}" == "arm64" ]]; then
            sed -i "s|ARCH|aarch64|g" "$dockerfile"
        else
            sed -i "s|ARCH|${arch}|g" "$dockerfile"
        fi
        sed -i "s/CROSS_BUILD_//g" "$dockerfile"
    fi
}

get-base-image() {
    local arch=$1
    
    # Parse architectures and variants
    if [[ $arch == amd64 ]]; then
        BASEIMAGE="ubuntu"
    elif [[ $arch == arm ]]; then
        BASEIMAGE="arm32v7/ubuntu"
    elif [[ $arch == arm64 ]]; then
        BASEIMAGE="arm64v8/ubuntu"
    elif [[ $arch == s390x ]]; then
        BASEIMAGE="s390x/ubuntu"
    elif [[ $arch == ppc64le ]]; then
        BASEIMAGE="ppc64le/ubuntu"
    fi

    makeDockerfile "${arch}"
}

sort-versions() {
    if [ "$(uname)" == 'Darwin' ]; then
        gsort --version-sort
    else
        sort --version-sort
    fi
}

login-token() {
    # could use jq .token
    curl -q -sSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REGISTRY/$IMAGE:pull" | grep -o '"token":"[^"]*"' | cut -d':' -f 2 | xargs echo
}

get-manifest() {
    local tag=$1
    local opts=""
    if [ "$debug" = true ]; then
        opts="-v"
    fi
    curl $opts -q -fsSL -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer $TOKEN" "https://index.docker.io/v2/$REGISTRY/$IMAGE/manifests/$tag"
}

# Make a list of platforms for manifest-tool to publish
parse-manifest-platforms() {
    local platforms=()
    for arch in ${ARCHS[*]}; do
        platforms+=("linux/$arch")
    done
    IFS=,;printf "%s" "${platforms[*]}"
}

publish() {
    local version=$1
    local tag="${version}"
    
    build_opts=(--no-cache --pull)

    for arch in ${ARCHS[*]}; do
        get-base-image "$arch"

        docker build --file "Dockerfile-$arch" \
                     --tag "$REGISTRY/$IMAGE:${tag}-${arch}" \
                     "${build_opts[@]+"${build_opts[@]}"}" .

        docker push "$REGISTRY/$IMAGE:${tag}-${arch}"
    done
}

push-manifest() {

    local version=$1
    
    ./manifest-tool push from-args \
        --platforms "$(parse-manifest-platforms)" \
        --template "$REGISTRY/$IMAGE:${version}-ARCH" \
        --target "$REGISTRY/$IMAGE:${version}"
}

cleanup() {
    echo "Cleaning up"
    rm -f manifest-tool
    rm -f qemu-*
    rm -rf Dockerfile-*
}

# Process arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d)
        debug=true
        ;;
        *)
        echo "Unknown option: $key"
        return 1
        ;;
    esac
    shift
done


if [ "$debug" = true ]; then
    set -x
fi

get-manifest-tool
get-qemu

# Register binfmt_misc to run cross platform builds against non x86 architectures
docker run --rm --privileged multiarch/qemu-user-static:register --reset

TOKEN=$(login-token)

publish "latest"
push-manifest "latest"

cleanup
