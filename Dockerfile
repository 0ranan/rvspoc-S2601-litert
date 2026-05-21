

# 为 Litert 提供封闭构建环境的 Docker 镜像。
FROM ubuntu:24.04

# 避免在软件包安装过程中出现交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# 主机代理：使用 host.docker.internal（通过 --add-host=host.docker.internal:host-gateway 映射到主机）。
# 在无 Desktop 的原生 Linux Docker 上，请覆盖：--build-arg PROXY_HOST=127.0.0.1 --network=host
ARG PROXY_HOST=host.docker.internal
ARG PROXY_PORT=7897
ENV http_proxy=http://${PROXY_HOST}:${PROXY_PORT} \
    https_proxy=http://${PROXY_HOST}:${PROXY_PORT} \
    all_proxy=socks5://${PROXY_HOST}:${PROXY_PORT} \
    HTTP_PROXY=http://${PROXY_HOST}:${PROXY_PORT} \
    HTTPS_PROXY=http://${PROXY_HOST}:${PROXY_PORT} \
    ALL_PROXY=socks5://${PROXY_HOST}:${PROXY_PORT} \
    NO_PROXY=localhost,127.0.0.1,host.docker.internal,mirrors.aliyun.com,pypi.tuna.tsinghua.edu.cn \
    no_proxy=localhost,127.0.0.1,host.docker.internal,mirrors.aliyun.com,pypi.tuna.tsinghua.edu.cn

# Ubuntu apt 镜像源（阿里云）
# RUN sed -i \
#     -e 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
#     -e 's|http://security.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
#     /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || \
#     sed -i \
#     's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g; \
#      s|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' \
#     /etc/apt/sources.list

# 配置 apt 重试次数和超时时间
RUN echo 'Acquire::Retries "10";' >> /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::http::Timeout "120";' >> /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::https::Timeout "120";' >> /etc/apt/apt.conf.d/80-retries && \
    echo 'Acquire::http::Pipeline-Depth "0";' >> /etc/apt/apt.conf.d/80-retries

# Ubuntu apt 镜像源（清华）
RUN sed -i \
    -e 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    -e 's|http://security.ubuntu.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || \
    sed -i \
    's|http://archive.ubuntu.com/ubuntu|http://mirrors.tuna.tsinghua.edu.cn/ubuntu|g; \
     s|http://security.ubuntu.com/ubuntu|http://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
    /etc/apt/sources.list

# pip 镜像源（清华）
RUN mkdir -p /root/.pip && printf '%s\n' \
    '[global]' \
    'index-url = https://pypi.tuna.tsinghua.edu.cn/simple' \
    'trusted-host = pypi.tuna.tsinghua.edu.cn' \
    > /root/.pip/pip.conf

# 安装基础依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl git wget unzip zip \
    python3 python3-pip python3-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# 安装 OpenJDK 17
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# 安装 LLVM 18
RUN apt-get update && apt-get install -y --no-install-recommends \
    llvm-18 clang-18 libc++-dev libc++abi-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 安装 Bazelisk 以处理自动 Bazel 版本管理
# RUN ARCH=$(uname -m) && \
#     if [ "$ARCH" = "x86_64" ]; then \
#         wget https://github.com/bazelbuild/bazelisk/releases/download/v1.18.0/bazelisk-linux-amd64 -O bazelisk; \
#     elif [ "$ARCH" = "aarch64" ]; then \
#         wget https://github.com/bazelbuild/bazelisk/releases/download/v1.18.0/bazelisk-linux-arm64 -O bazelisk; \
#     else \
#         echo "Unsupported architecture: $ARCH"; \
#         exit 1; \
#     fi && \
#     chmod +x bazelisk && \
#     mv bazelisk /usr/local/bin/bazel && \
#     # 设置 USE_BAZEL_VERSION 确保 bazelisk 下载正确的版本
#     echo "export USE_BAZEL_VERSION=7.4.1" >> /etc/bash.bashrc

# 安装Camke
# 下载并安装指定版本的 CMake
COPY package/ /tmp/package/
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        tar -xzf /tmp/package/cmake-4.0.7-linux-x86_64.tar.gz -C /usr/local --strip-components=1 ; \
    else \
        echo "Unsupported architecture: $ARCH"; \
        exit 1; \
    fi && \
    rm -rf /tmp/package

# 初始化并拉取 TensorFlow 子模块（注意：这会拉取完整的 tensorflow 仓库，非常大）



# 软链接 clang-18 和 llvm-18 到系统路径
RUN ln -s /usr/bin/clang-18 /usr/bin/clang && \
    ln -s /usr/bin/clang++-18 /usr/bin/clang++ && \
    ln -s /usr/bin/llvm-18 /usr/bin/llvm

RUN mkdir -p /opt/toolchains && \
    printf '%s\n' \
    'set(CMAKE_SYSTEM_NAME Linux)' \
    'set(CMAKE_SYSTEM_PROCESSOR riscv64)' \
    '' \
    'set(TOOLCHAIN_PREFIX riscv64-unknown-linux-gnu)' \
    '' \
    'set(CMAKE_C_COMPILER   ${TOOLCHAIN_PREFIX}-gcc)' \
    'set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}-g++)' \
    'set(CMAKE_AR           ${TOOLCHAIN_PREFIX}-ar      CACHE FILEPATH "")' \
    'set(CMAKE_AS           ${TOOLCHAIN_PREFIX}-as      CACHE FILEPATH "")' \
    'set(CMAKE_LINKER       ${TOOLCHAIN_PREFIX}-ld      CACHE FILEPATH "")' \
    'set(CMAKE_OBJCOPY      ${TOOLCHAIN_PREFIX}-objcopy CACHE FILEPATH "")' \
    'set(CMAKE_OBJDUMP      ${TOOLCHAIN_PREFIX}-objdump CACHE FILEPATH "")' \
    'set(CMAKE_RANLIB       ${TOOLCHAIN_PREFIX}-ranlib  CACHE FILEPATH "")' \
    'set(CMAKE_STRIP        ${TOOLCHAIN_PREFIX}-strip   CACHE FILEPATH "")' \
    '' \
    'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)' \
    'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)' \
    'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)' \
    'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)' \
    '' \
    'set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=rv64gc" CACHE STRING "")' \
    'set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=rv64gc" CACHE STRING "")' \
    > /opt/toolchains/riscv64-unknown-linux-gnu.cmake

