# 使用 Docker 构建

本仓库提供了一个基于 Docker 的封闭构建环境，可自动配置构建项目所需的所有依赖项，无需手动配置或设置。它可以在单个步骤中处理 git 子模块初始化和项目配置。

## 前提条件

- 您的机器上已安装 Docker


## 相关环境下载

拉取 TensorFlow 子模块。

```bash
# 初始化并拉取 TensorFlow 子模块（注意：这会拉取完整的 tensorflow 仓库，非常大）
git submodule update --init  third_party/tensorflow

# 后续使用时，直接指定 TensorFlow 源目录即可
# -DTENSORFLOW_SOURCE_DIR=/home/anran/Desktop/code/rvspoc-S2601-litert/third_party/tensorflow
```

## 从网络下载相关资源

```bash
mkdir package

wget https://github.com/Kitware/CMake/releases/download/v4.0.7/cmake-4.0.7-linux-x86_64.tar.gz -P ./package

wget https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2026.05.19/riscv64-glibc-ubuntu-24.04-gcc.tar.xz -P ./package

wget https://soc-developer.semiconductor.samsung.com/api/v1/resource/download-file/1.1.0/ai-litecore-ubuntu2404-v1.1.0.tar.gz -P ./vendor_headers

wget https://s3.ap-southeast-1.amazonaws.com/mediatek.neuropilot.com/66f2c33a-2005-4f0b-afef-2053c8654e4f.gz -P ./vendor_headers

wget https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.44.0.260225/v2.44.0.260225.zip -P ./vendor_headers

```

## 解压 vendor headers

下载完成后，在项目根目录执行以下解压操作。**注意：所有解压操作必须在项目根目录下执行**，确保解压后的目录结构相对于 `./vendor_headers` 保持一致，否则 CMake 构建系统将无法正确定位头文件路径。

```bash
# 1. 解压 Samsung AI LiteCore
tar -xzf ./vendor_headers/ai-litecore-ubuntu2404-v1.1.0.tar.gz -C ./vendor_headers
# 2. 解压 MediaTek NeuroPilot
tar -xzf ./vendor_headers/66f2c33a-2005-4f0b-afef-2053c8654e4f.gz -C ./vendor_headers
# 3. 解压 Qualcomm QAIRT
unzip ./vendor_headers/v2.44.0.260225.zip -d ./vendor_headers
```

## 使用 docker compose 开发环境

修改根目录下的Dockerfile的网络代理
```
ARG PROXY_HOST={你的代理IP}
ARG PROXY_PORT={你的代理端口}
```

构建开发环境
```bash
docker compose build
```

启动开发环境
```bash
docker compose up -d dev
```

进入容器
```bash
docker compose exec dev bash
```



## 使用 DockerCompose 构建 benchmark_model

### 配置 CMake 构建

```bash
docker compose exec dev bash
cd /app/litert/
cmake -S . -B build-riscv64 \
      -DCMAKE_BUILD_TYPE=Release \
      -DLITERT_AUTO_BUILD_TFLITE=ON \
      -DLITERT_ENABLE_GPU=OFF \
      -DLITERT_ENABLE_NPU=OFF \
      -DLITERT_DISABLE_KLEIDIAI=ON \
      -DTFLITE_ENABLE_XNNPACK=OFF \
      -DBENCHMARK_ENABLE_TESTING=OFF \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DProtobuf_PROTOC_EXECUTABLE=/usr/bin/protoc \
      -DCMAKE_C_COMPILER=/opt/riscv64-glibc/bin/riscv64-unknown-linux-gnu-gcc \
      -DCMAKE_CXX_COMPILER=/opt/riscv64-glibc/bin/riscv64-unknown-linux-gnu-g++ \
      -DLITERT_HOST_C_COMPILER=/usr/bin/clang \
      -DLITERT_HOST_CXX_COMPILER=/usr/bin/clang++ \
      -DTENSORFLOW_SOURCE_DIR=../third_party/tensorflow \
      -DNEUROPILOT_HEADERS_DIR=../vendor_headers/neuro_pilot/v8_0_8/host/include \
      -DQAIRT_HEADERS_DIR=../vendor_headers/qairt/2.44.0.260225/include/QNN \
      -DLITECORE_HEADERS_DIR=../vendor_headers/exynos-ai-litecore-v1.1.0/include \
      -DCMAKE_SYSTEM_PROCESSOR=riscv64 \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DTFLITE_HOST_TOOLS_DIR=/app/host_flatc_build/_deps/flatbuffers-build \
      2>&1 | tee cmake_config_riscv64.log
```

###构建benchmark_model

```bash

docker compose exec dev bash
cd /app/litert/
# 使用多线程编译并查看详细输出
cmake --build build-riscv64 --target benchmark_model -j$(nproc) 2>&1 | tee build.log
```

### 测试benchmark_model

```bash
./scripts/deploy_benchmark.sh 
```