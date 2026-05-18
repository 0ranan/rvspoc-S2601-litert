# CMake 构建指南

本文档整合了项目的环境搭建、CMake 构建配置、以及 benchmark_model 的构建与测试流程。

---

## 1. 环境初始化

### 1.1 拉取 TensorFlow 子模块

```bash
# 初始化并拉取 TensorFlow 子模块（注意：这会拉取完整的 tensorflow 仓库，非常大）
git submodule update --init third_party/tensorflow

# 后续使用时，直接指定 TensorFlow 源目录即可
# -DTENSORFLOW_SOURCE_DIR=/path/to/rvspoc-S2601-litert/third_party/tensorflow
```

### 1.2 下载依赖

```bash
# 创建 package 目录
mkdir -p package

# 下载 CMake (v4.0.7)
wget https://github.com/Kitware/CMake/releases/download/v4.0.7/cmake-4.0.7-linux-x86_64.tar.gz -P ./package

# 下载 Vendor SDK Headers
wget https://soc-developer.semiconductor.samsung.com/api/v1/resource/download-file/1.1.0/ai-litecore-ubuntu2404-v1.1.0.tar.gz -P ./vendor_headers

wget https://s3.ap-southeast-1.amazonaws.com/mediatek.neuropilot.com/66f2c33a-2005-4f0b-afef-2053c8654e4f.gz -P ./vendor_headers

wget https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.44.0.260225/v2.44.0.260225.zip -P ./vendor_headers
```

### 1.3 解压 Vendor Headers

下载完成后，在项目根目录执行以下解压操作。**注意：所有解压操作必须在项目根目录下执行**，确保解压后的目录结构相对于 `./vendor_headers` 保持一致，否则 CMake 构建系统将无法正确定位头文件路径。

```bash
# 1. 解压 Samsung AI LiteCore
tar -xzf ./vendor_headers/ai-litecore-ubuntu2404-v1.1.0.tar.gz -C ./vendor_headers

# 2. 解压 MediaTek NeuroPilot
tar -xzf ./vendor_headers/66f2c33a-2005-4f0b-afef-2053c8654e4f.gz -C ./vendor_headers

# 3. 解压 Qualcomm QAIRT
unzip ./vendor_headers/v2.44.0.260225.zip -d ./vendor_headers
```

### 1.4 启动开发环境

使用 Docker Compose 启动开发容器：

```bash
# 启动开发环境
docker compose up -d dev

# 进入容器
docker compose exec dev bash
```

---

## 2. CMake 构建

以下操作均在 Docker 开发容器内执行（先执行 `docker compose exec dev bash` 进入容器）。

### 2.1 配置 CMake

```bash
cd /app/litert/

cmake -S . -B build-release \
      -DCMAKE_BUILD_TYPE=Release \
      -DLITERT_AUTO_BUILD_TFLITE=ON \
      -DLITERT_ENABLE_GPU=OFF \
      -DLITERT_ENABLE_NPU=OFF \
      -DLITERT_DISABLE_KLEIDIAI=ON \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DTENSORFLOW_SOURCE_DIR=../third_party/tensorflow \
      -DCMAKE_C_COMPILER=/usr/bin/clang \
      -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
      -DLITERT_HOST_C_COMPILER=/usr/bin/clang \
      -DLITERT_HOST_CXX_COMPILER=/usr/bin/clang++ \
      -DNEUROPILOT_HEADERS_DIR=../vendor_headers/neuro_pilot/v8_0_8/host/include \
      -DQAIRT_HEADERS_DIR=../vendor_headers/qairt/2.44.0.260225/include/QNN \
      -DLITECORE_HEADERS_DIR=../vendor_headers/exynos-ai-litecore-v1.1.0/include \
      2>&1 | tee cmake_config.log
```

### 2.2 构建 benchmark_model

```bash
cd /app/litert/

# 使用多线程编译并查看详细输出
cmake --build build-release --target benchmark_model -j$(nproc) 2>&1 | tee build.log
```

---

## 3. 测试与部署

### 3.1 部署 benchmark_model

编译完成后，在项目根目录（主机端）执行部署脚本，将 benchmark_model 发送到远端设备进行测试：

```bash
./scripts/deploy_benchmark.sh
```

该脚本支持：
- 通过 SCP 发送 `benchmark_model` 到远端机器
- 通过 SSH 在远端执行测试
- 首次运行时交互式输入 SSH 配置（IP、端口、用户名、密码），自动保存到 `.deploy_config`
- 支持通过环境变量 `BENCHMARK_PATH` 和 `BENCHMARK_ARGS` 自定义测试参数

---

> **参考**: 更多详细信息可查阅 [docker_build 文档](../docker_build/README.md)。