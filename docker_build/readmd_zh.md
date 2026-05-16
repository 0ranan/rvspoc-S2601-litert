# 使用 Docker 构建

本仓库提供了一个基于 Docker 的封闭构建环境，可自动配置构建项目所需的所有依赖项，无需手动配置或设置。它可以在单个步骤中处理 git 子模块初始化和项目配置。

## 前提条件

- 您的机器上已安装 Docker
- Docker Compose（可选，用于使用 docker-compose.yml）

## 使用 Docker 脚本构建

1. 克隆此仓库
2. 运行构建脚本：
   ```
   ./build_with_docker.sh
   ```

这将：

- 构建包含所有必要依赖项的 Docker 镜像
- 运行容器，挂载当前的 litert 检出目录
- 生成配置文件 (.litert_configure.bazelrc)
- 构建目标。我们以 `//litert/runtime:compiled_model` 为例

## 使用 Docker Compose 构建

或者，您可以使用 Docker Compose：

```
docker-compose up
```

## 自定义构建

要构建不同的目标，您可以：

1. 修改 `hermetic_build.Dockerfile` 并更改 CMD 行
2. 修改 `docker-compose.yml` 中的命令
3. 运行 Docker 时传递自定义命令：
   ```
   # 从仓库根目录运行此命令。
   docker run --rm --user $(id -u):$(id -g) -v $(pwd):/litert_build litert_build_env bash -c "bazel build //litert/your_custom:target"
   ```

## 访问构建产物

从容器中复制产物：
```
docker cp <container>:/litert_build/bazel-bin/<path> .
```
（`litert_build_container` 是 `build_with_docker.sh` 使用的名称。对于 Docker Compose，请使用 `docker ps -a` 查找名称。）

要从容器 shell 中浏览输出，请运行（从仓库根目录）：
```
docker run --rm -it --user $(id -u):$(id -g) -e HOME=/litert_build -e USER=$(id -un) -v $(pwd):/litert_build litert_build_env bash
```

## 工作原理

Docker 环境：
1. 设置 Ubuntu 24.04 构建环境（使用更新的 libc/libc++）
2. 安装 Bazel 7.4.1 和必要的构建工具
3. 配置正确版本的 Android SDK 和 NDK
4. 自动初始化和更新 git 子模块
5. 自动生成 .litert_configure.bazelrc 文件
6. 提供独立于本地设置的封闭构建环境

## 故障排除

如果遇到构建错误：

1. 检查 Docker 守护进程是否分配了足够的 RAM 和 CPU
2. 确保您有挂载当前目录的适当权限
3. 检查 Docker 日志以获取特定错误消息

您可以在容器中运行 shell 进行调试（从仓库根目录）：
```
docker run --rm -it --user $(id -u):$(id -g) -e HOME=/litert_build -e USER=$(id -un) -v $(pwd):/litert_build litert_build_env bash
```
