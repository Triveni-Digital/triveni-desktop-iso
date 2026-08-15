FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Install core requirements
RUN apt-get update && apt-get install -y curl gnupg ca-certificates

# Set up NodeSource for Node 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

# Combined Install (Fixed path and simplified)
RUN apt update && apt install -y \
    nodejs \
    net-tools zlib1g-dev g++ \
    libboost-all-dev libboost-tools-dev \
    libboost-url-dev libboost-regex-dev \
    libboost-contract-dev \
    libcrypto++-dev libprotobuf-dev libprotoc-dev protobuf-compiler libcurl4-openssl-dev libxml2-dev \
    libgnutls28-dev libsrt-openssl-dev libxmlsec1-dev flex bison \
    openjdk-8-jdk \
    subversion ant cmake make fakeroot build-essential devscripts \
    genisoimage fuseiso autoconf automake git-core libtool \
    meson nasm ninja-build pkg-config texinfo wget yasm \
    libpcap-dev libssl-dev libsnmp-dev \
    libass-dev libfreetype6-dev libsdl2-dev \
    libva-dev libvdpau-dev libvorbis-dev \
    libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
    openssl libevent-dev libnspr4-dev libnuma-dev 

RUN apt install -y xorriso fdisk squashfs-tools mount

WORKDIR /workspace

