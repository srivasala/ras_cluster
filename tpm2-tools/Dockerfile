FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y \
      git build-essential autoconf automake libtool pkg-config \
      libssl-dev libcurl4-gnutls-dev python3-yaml \
      autoconf-archive acl libjson-c-dev doxygen \
      libgcrypt20-dev libgmp-dev libsqlite3-dev libdbus-1-dev \
      libglib2.0-dev libseccomp-dev \
      wget \
      && rm -rf /var/lib/apt/lists/*

# Build tpm2-tss
RUN git clone https://github.com/tpm2-software/tpm2-tss.git && \
    cd tpm2-tss && \
    ./bootstrap && \
    ./configure --prefix=/usr && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf tpm2-tss

# Build tpm2-tools
RUN git clone https://github.com/tpm2-software/tpm2-tools.git && \
    cd tpm2-tools && \
    ./bootstrap && \
    ./configure --prefix=/usr && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf tpm2-tools

ENTRYPOINT ["/bin/bash"]

