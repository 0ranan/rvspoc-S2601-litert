

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
    protobuf-compiler \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# 安装 OpenJDK 17
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# 安装 LLVM 18
RUN apt-get update && apt-get install -y --no-install-recommends \
    llvm-18 clang-18 libc++-dev libc++abi-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# 安装 RISC-V GCC 交叉编译工具链
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
#     && apt-get clean && rm -rf /var/lib/apt/lists/*
# 安装 ARM64 (aarch64) GCC 交叉编译工具链
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
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

# 拷贝预下载包
COPY package/ /tmp/package/


# 安装riscv gcc
RUN mkdir -p /opt/riscv64-glibc && \
    tar -xvf /tmp/package/riscv64-glibc-ubuntu-24.04-gcc.tar.xz -C /opt/riscv64-glibc --strip-components=1 

# 配置环境变量
ENV PATH=/opt/riscv64-glibc/bin/:${PATH}

# 安装Camke
# 下载并安装指定版本的 CMake
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
