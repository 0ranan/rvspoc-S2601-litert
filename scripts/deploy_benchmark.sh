#!/bin/bash
#
# deploy_benchmark.sh
# 功能：
#   1. 通过 SCP 发送benchmark_model到远端机器
#   2. 通过 SSH 在远端执行
#   3. 自动管理 SSH 配置（IP/端口/用户名/密码），首次运行时交互式输入并保存
#
# BUILD_DIR 参数说明：
#   BUILD_DIR 指定 CMake 构建输出目录的路径，用于定位 benchmark_model 二进制文件。
#   该参数支持以下传递方式（优先级从高到低）：
#     1. 命令行参数:  --build-dir <路径>
#     2. 环境变量:    BUILD_DIR=<路径>
#     3. 配置文件:    .deploy_config 中 BUILD_DIR="<路径>"
#     4. 默认值:      ${PROJECT_DIR}/build-release
#   对于 RISC-V 架构构建，典型值为 build-riscv64，例如：
#     ./deploy_benchmark.sh --build-dir /path/to/project/build-riscv64
#   当 BUILD_DIR 有效时，脚本会自动在 ${BUILD_DIR} 下查找 benchmark_model 二进制，
#   并将其作为 BENCHMARK_BIN 的默认候选路径，减少手动输入。

set -euo pipefail

# ========================== 命令行参数解析 ==========================
# 解析 --build-dir 参数，用于指定 CMake 构建输出目录
# 用法: --build-dir <路径>  或  --build-dir=<路径>
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-dir=*)
                CLI_BUILD_DIR="${1#--build-dir=}"
                shift
                ;;
            --build-dir)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}[ERROR]${NC} --build-dir 需要一个参数" >&2
                    exit 1
                fi
                CLI_BUILD_DIR="$2"
                shift 2
                ;;
            -h|--help)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --build-dir <路径>  指定 CMake 构建输出目录路径"
                echo "                      (默认: \${PROJECT_DIR}/build-release)"
                echo "                      RISC-V 构建典型值: build-riscv64"
                echo "  -h, --help          显示此帮助信息"
                echo ""
                echo "环境变量:"
                echo "  BUILD_DIR           CMake 构建输出目录 (可被 --build-dir 覆盖)"
                echo "  BENCHMARK_PATH      本地 .tflite 模型文件路径"
                echo "  BENCHMARK_ARGS      benchmark_model 运行附加参数"
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} 未知参数: $1" >&2
                echo "使用 --help 查看用法" >&2
                exit 1
                ;;
        esac
    done
}

# ========================== 配置区 ==========================
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# BUILD_DIR: CMake 构建输出目录，用于定位 benchmark_model 二进制文件
# 优先级: 命令行参数 > 环境变量 > 配置文件 > 默认值
# 默认值为 build-release，RISC-V 构建应使用 build-riscv64
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build-release}"
CLI_BUILD_DIR=""
CONFIG_FILE="${PROJECT_DIR}/.deploy_config"
REMOTE_DIR="/tmp"
REMOTE_BINARY_NAME="benchmark_model"
BENCHMARK_PATH="${BENCHMARK_PATH:-}"
BENCHMARK_ARGS="${BENCHMARK_ARGS:-}"
RESULT_DIR="${PROJECT_DIR}/benchmark_results"

# ========================== 颜色输出 ==========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ========================== 读取/写入配置文件 ==========================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

validate_and_fill_config() {
    local need_save=false

    if [[ -z "${SSH_IP:-}" ]]; then
        read -r -p "请输入远端 IP 地址: " SSH_IP
        need_save=true
    fi

    if [[ -z "${SSH_PORT:-}" ]]; then
        read -r -p "请输入 SSH 端口 (默认 22): " SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"
        need_save=true
    fi

    if [[ -z "${SSH_USER:-}" ]]; then
        read -r -p "请输入 SSH 用户名: " SSH_USER
        need_save=true
    fi

    if [[ -z "${SSH_PASS:-}" ]]; then
        read -r -s -p "请输入 SSH 密码: " SSH_PASS
        echo
        need_save=true
    fi

    if $need_save; then
        info "配置已更新，保存到 ${CONFIG_FILE}"
        cat > "$CONFIG_FILE" <<EOF
SSH_IP="${SSH_IP}"
SSH_PORT="${SSH_PORT}"
SSH_USER="${SSH_USER}"
SSH_PASS="${SSH_PASS}"
BUILD_DIR="${BUILD_DIR}"
BENCHMARK_BIN="${BENCHMARK_BIN:-}"
BENCHMARK_PATH="${BENCHMARK_PATH:-}"
EOF
        chmod 600 "$CONFIG_FILE"
        success "配置文件已保存 (权限 600)"
    fi
}

# ========================== BUILD_DIR 验证 ==========================
# 验证 BUILD_DIR 的有效性：
#   1. 命令行参数 --build-dir 优先级最高，会覆盖环境变量和配置文件中的值
#   2. 检查路径是否为有效目录
#   3. 检查目录中是否存在 CMake 构建产物（如 CMakeCache.txt）以确认是合法的构建目录
#   4. 将最终确定的 BUILD_DIR 保存到配置文件，供后续使用
save_build_dir_to_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if grep -q "^BUILD_DIR=" "$CONFIG_FILE"; then
            sed -i "s|^BUILD_DIR=.*|BUILD_DIR=\"${BUILD_DIR}\"|" "$CONFIG_FILE"
        else
            echo "BUILD_DIR=\"${BUILD_DIR}\"" >> "$CONFIG_FILE"
        fi
    fi
}

validate_build_dir() {
    # 命令行参数优先级最高，覆盖环境变量和配置文件中的值
    if [[ -n "${CLI_BUILD_DIR:-}" ]]; then
        BUILD_DIR="${CLI_BUILD_DIR}"
        info "使用命令行指定的 BUILD_DIR: ${BUILD_DIR}"
    fi

    # 解析为绝对路径
    if [[ -n "${BUILD_DIR}" ]]; then
        BUILD_DIR="$(realpath "${BUILD_DIR}" 2>/dev/null || echo "${BUILD_DIR}")"
    fi

    # 检查路径是否为空
    if [[ -z "${BUILD_DIR}" ]]; then
        warn "BUILD_DIR 为空，将使用默认值: ${PROJECT_DIR}/build-release"
        BUILD_DIR="${PROJECT_DIR}/build-release"
    fi

    # 检查目录是否存在
    if [[ ! -d "${BUILD_DIR}" ]]; then
        warn "BUILD_DIR 目录不存在: ${BUILD_DIR}"
        warn "  这可能意味着尚未执行 CMake 配置和构建"
        warn "  脚本将继续运行，但可能无法自动定位 benchmark_model 二进制文件"
        save_build_dir_to_config
        return 0
    fi

    # 检查是否为有效的 CMake 构建目录（存在 CMakeCache.txt 或 Makefile 等标志文件）
    if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]] || [[ -f "${BUILD_DIR}/Makefile" ]]; then
        success "BUILD_DIR 校验通过: ${BUILD_DIR} (有效的 CMake 构建目录)"
    else
        warn "BUILD_DIR 不是标准的 CMake 构建目录: ${BUILD_DIR}"
        warn "  未找到 CMakeCache.txt 或 Makefile，该目录可能不是构建输出目录"
    fi

    # 检查构建目录中是否已存在 benchmark_model 二进制
    local expected_bin="${BUILD_DIR}/${REMOTE_BINARY_NAME}"
    if [[ -f "${expected_bin}" ]] && [[ -x "${expected_bin}" ]]; then
        success "在 BUILD_DIR 中发现 benchmark_model: ${expected_bin}"
    else
        info "BUILD_DIR 中未找到可执行的 benchmark_model (预期路径: ${expected_bin})"
        info "  后续将需要手动指定 BENCHMARK_BIN 路径"
    fi

    save_build_dir_to_config
    success "BUILD_DIR 已保存到配置文件: ${BUILD_DIR}"
}

# ========================== BENCHMARK_BIN 输入与校验 ==========================
save_benchmark_bin_to_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if grep -q "^BENCHMARK_BIN=" "$CONFIG_FILE"; then
            sed -i "s|^BENCHMARK_BIN=.*|BENCHMARK_BIN=\"${BENCHMARK_BIN}\"|" "$CONFIG_FILE"
        else
            echo "BENCHMARK_BIN=\"${BENCHMARK_BIN}\"" >> "$CONFIG_FILE"
        fi
        if grep -q "^BUILD_DIR=" "$CONFIG_FILE"; then
            sed -i "s|^BUILD_DIR=.*|BUILD_DIR=\"${BUILD_DIR}\"|" "$CONFIG_FILE"
        else
            echo "BUILD_DIR=\"${BUILD_DIR}\"" >> "$CONFIG_FILE"
        fi
    else
        cat > "$CONFIG_FILE" <<EOF
SSH_IP="${SSH_IP:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-}"
SSH_PASS="${SSH_PASS:-}"
BUILD_DIR="${BUILD_DIR}"
BENCHMARK_BIN="${BENCHMARK_BIN}"
BENCHMARK_PATH="${BENCHMARK_PATH:-}"
EOF
        chmod 600 "$CONFIG_FILE"
    fi
}

validate_and_input_benchmark_bin() {
    local input_by_user=false

    # 尝试基于 BUILD_DIR 自动推断 BENCHMARK_BIN 的默认路径
    # 当 BENCHMARK_BIN 未配置时，在 BUILD_DIR 下查找 benchmark_model 二进制
    local auto_detected_bin="${BUILD_DIR}/${REMOTE_BINARY_NAME}"

    if [[ -n "${BENCHMARK_BIN:-}" ]]; then
        info "使用已配置的 BENCHMARK_BIN: ${BENCHMARK_BIN}"

        if [[ ! -f "${BENCHMARK_BIN}" ]]; then
            error "BENCHMARK_BIN 指向的文件不存在: ${BENCHMARK_BIN}"
            warn "将重新输入..."
            BENCHMARK_BIN=""
            input_by_user=true
        elif [[ ! -x "${BENCHMARK_BIN}" ]]; then
            error "BENCHMARK_BIN 指向的文件不可执行: ${BENCHMARK_BIN}"
            warn "将重新输入..."
            BENCHMARK_BIN=""
            input_by_user=true
        else
            success "BENCHMARK_BIN 校验通过"
            return 0
        fi
    else
        input_by_user=true
    fi

    # 如果 BUILD_DIR 下存在可执行的 benchmark_model，自动使用该路径
    if $input_by_user && [[ -f "${auto_detected_bin}" ]] && [[ -x "${auto_detected_bin}" ]]; then
        info "在 BUILD_DIR 中自动发现 benchmark_model: ${auto_detected_bin}"
        BENCHMARK_BIN="${auto_detected_bin}"
        success "BENCHMARK_BIN 自动检测通过: ${BENCHMARK_BIN}"
        save_benchmark_bin_to_config
        success "BENCHMARK_BIN 已保存到配置文件"
        return 0
    fi

    local max_attempts=3
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        echo ""
        # 提示用户输入，并显示基于 BUILD_DIR 的推荐路径
        local prompt_hint=""
        if [[ -d "${BUILD_DIR}" ]]; then
            prompt_hint=" (推荐: ${auto_detected_bin})"
        fi
        read -r -p "请输入 benchmark_model 二进制文件的路径${prompt_hint}: " BENCHMARK_BIN

        # 如果用户直接按回车，尝试使用 BUILD_DIR 下的默认路径
        if [[ -z "${BENCHMARK_BIN}" ]] && [[ -f "${auto_detected_bin}" ]] && [[ -x "${auto_detected_bin}" ]]; then
            BENCHMARK_BIN="${auto_detected_bin}"
            info "使用 BUILD_DIR 下的默认路径: ${BENCHMARK_BIN}"
            success "BENCHMARK_BIN 校验通过: ${BENCHMARK_BIN}"
            break
        fi

        if [[ -z "${BENCHMARK_BIN}" ]]; then
            error "输入不能为空 (第 ${attempt}/${max_attempts} 次尝试)"
            continue
        fi

        BENCHMARK_BIN="$(realpath "${BENCHMARK_BIN}" 2>/dev/null || echo "${BENCHMARK_BIN}")"

        if [[ ! -f "${BENCHMARK_BIN}" ]]; then
            error "文件不存在: ${BENCHMARK_BIN} (第 ${attempt}/${max_attempts} 次尝试)"
            continue
        fi

        if [[ ! -x "${BENCHMARK_BIN}" ]]; then
            error "文件不可执行: ${BENCHMARK_BIN} (第 ${attempt}/${max_attempts} 次尝试)"
            echo "         提示: 请先赋予可执行权限 chmod +x <文件路径>"
            continue
        fi

        input_by_user=true
        success "BENCHMARK_BIN 校验通过: ${BENCHMARK_BIN}"
        break
    done

    if [[ $attempt -ge $max_attempts ]] && [[ -z "${BENCHMARK_BIN}" ]]; then
        error "输入失败，已达到最大尝试次数 (${max_attempts})"
        exit 1
    fi

    if $input_by_user; then
        save_benchmark_bin_to_config
        success "BENCHMARK_BIN 已保存到配置文件"
    fi

    return 0
}

# ========================== 模型文件输入、同步与校验 ==========================
save_model_path_to_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if grep -q "^BENCHMARK_PATH=" "$CONFIG_FILE"; then
            sed -i "s|^BENCHMARK_PATH=.*|BENCHMARK_PATH=\"${BENCHMARK_PATH}\"|" "$CONFIG_FILE"
        else
            echo "BENCHMARK_PATH=\"${BENCHMARK_PATH}\"" >> "$CONFIG_FILE"
        fi
    fi
}

get_remote_file_checksum() {
    local remote_file="$1"
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_IP}" \
        "md5sum '${remote_file}' 2>/dev/null | cut -d' ' -f1" 2>/dev/null
}

validate_and_sync_model() {
    local input_by_user=false

    # ---------- 1. 加载/输入 BENCHMARK_PATH ----------
    if [[ -n "${BENCHMARK_PATH:-}" ]]; then
        info "使用已配置的 BENCHMARK_PATH: ${BENCHMARK_PATH}"
        if [[ ! -f "${BENCHMARK_PATH}" ]]; then
            error "BENCHMARK_PATH 指向的文件不存在: ${BENCHMARK_PATH}"
            warn "将重新输入..."
            BENCHMARK_PATH=""
            input_by_user=true
        fi
    else
        input_by_user=true
    fi

    if $input_by_user; then
        local max_attempts=3
        local attempt=0
        while [[ $attempt -lt $max_attempts ]]; do
            attempt=$((attempt + 1))
            echo ""
            read -r -p "请输入本地 .tflite 模型文件的路径: " BENCHMARK_PATH

            if [[ -z "${BENCHMARK_PATH}" ]]; then
                error "输入不能为空 (第 ${attempt}/${max_attempts} 次尝试)"
                continue
            fi

            BENCHMARK_PATH="$(realpath "${BENCHMARK_PATH}" 2>/dev/null || echo "${BENCHMARK_PATH}")"

            if [[ ! -f "${BENCHMARK_PATH}" ]]; then
                error "文件不存在: ${BENCHMARK_PATH} (第 ${attempt}/${max_attempts} 次尝试)"
                continue
            fi

            break
        done

        if [[ $attempt -ge $max_attempts ]] && [[ -z "${BENCHMARK_PATH}" ]]; then
            error "模型文件输入失败，已达到最大尝试次数 (${max_attempts})"
            exit 1
        fi

        save_model_path_to_config
        success "模型路径已保存到配置文件"
    fi

    success "本地模型文件: ${BENCHMARK_PATH}"

    # ---------- 2. 计算本地 MD5 ----------
    info "计算本地模型 MD5 校验值..."
    if ! command -v md5sum &>/dev/null; then
        error "缺少 md5sum 命令，无法进行一致性检查"
        exit 1
    fi

    local local_md5
    local_md5="$(md5sum "${BENCHMARK_PATH}" | cut -d' ' -f1)"
    if [[ -z "${local_md5}" ]]; then
        error "无法计算本地模型 MD5 值"
        exit 1
    fi
    success "本地 MD5: ${local_md5}"

    # ---------- 3. 确定远端路径 ----------
    local model_basename
    model_basename="$(basename "${BENCHMARK_PATH}")"
    REMOTE_MODEL_PATH="${REMOTE_DIR}/${model_basename}"

    # ---------- 4. 远端一致性检查 ----------
    info "检查远端模型状态..."
    local remote_md5
    remote_md5="$(get_remote_file_checksum "${REMOTE_MODEL_PATH}")"

    if [[ -z "${remote_md5}" ]]; then
        warn "远端模型不存在: ${REMOTE_MODEL_PATH}"
    elif [[ "${remote_md5}" == "${local_md5}" ]]; then
        success "远端模型与本地一致 (MD5: ${remote_md5})，无需上传"
        echo ""
        return 0
    else
        warn "远端模型与本地不一致"
        warn "  本地 MD5: ${local_md5}"
        warn "  远端 MD5: ${remote_md5}"
    fi

    # ---------- 5. 上传模型 ----------
    info "正在上传模型到远端 ${SSH_USER}@${SSH_IP}:${REMOTE_MODEL_PATH} ..."

    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
        -P "${SSH_PORT}" \
        "${BENCHMARK_PATH}" \
        "${SSH_USER}@${SSH_IP}:${REMOTE_MODEL_PATH}"

    if [[ $? -ne 0 ]]; then
        error "模型文件上传失败，请检查远端磁盘空间和权限"
        exit 1
    fi
    success "模型上传完成"

    # ---------- 6. 上传后二次校验 ----------
    info "校验上传后的远端模型..."
    remote_md5="$(get_remote_file_checksum "${REMOTE_MODEL_PATH}")"
    if [[ "${remote_md5}" != "${local_md5}" ]]; then
        error "上传校验失败：远端 MD5 (${remote_md5}) 与本地 (${local_md5}) 不一致"
        error "请检查网络传输完整性后重试"
        exit 1
    fi
    success "上传校验通过，远端模型与本地一致"

    echo ""
}

# ========================== 依赖检查 ==========================
check_dependencies() {
    info "检查依赖..."

    local missing=()

    for cmd in cmake sshpass scp ssh; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少以下依赖: ${missing[*]}"
        echo ""
        echo "请安装缺失的工具，例如:"
        echo "  sudo apt-get install -y cmake sshpass openssh-client"
        exit 1
    fi

    success "所有依赖已就绪"
}

# ========================== 测试 SSH 连接 ==========================
test_ssh_connection() {
    info "测试 SSH 连接 ${SSH_USER}@${SSH_IP}:${SSH_PORT} ..."

    if sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_IP}" "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
        success "SSH 连接测试成功"
    else
        error "SSH 连接失败，请检查 IP/端口/用户名/密码是否正确"
        exit 1
    fi
}

# ========================== SCP 上传 + 远端执行 + 结果保存 ==========================
deploy_and_run() {
    local remote_bin_path="${REMOTE_DIR}/${REMOTE_BINARY_NAME}"
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local model_name
    model_name="$(basename "${BENCHMARK_PATH}" .tflite)"
    local result_file="${RESULT_DIR}/benchmark_${model_name}_${timestamp}.log"
    local local_host
    local_host="$(hostname 2>/dev/null || echo 'unknown')"

    mkdir -p "${RESULT_DIR}"

    # ---------- 上传 benchmark_model ----------
    info "上传 benchmark_model 到远端 ${SSH_USER}@${SSH_IP}:${remote_bin_path} ..."

    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
        -P "${SSH_PORT}" \
        "${BENCHMARK_BIN}" \
        "${SSH_USER}@${SSH_IP}:${remote_bin_path}"

    if [[ $? -ne 0 ]]; then
        error "benchmark_model 上传失败，请检查远端磁盘空间和权限"
        exit 1
    fi
    success "benchmark_model 上传完成"

    # ---------- 拼接运行参数 ----------
    local full_args="--graph=${REMOTE_MODEL_PATH}"
    if [[ -n "${BENCHMARK_ARGS}" ]]; then
        if [[ "${BENCHMARK_ARGS}" =~ --graph= ]]; then
            warn "BENCHMARK_ARGS 中已包含 --graph 参数，将被自动覆盖为: --graph=${REMOTE_MODEL_PATH}"
        fi
        full_args="${full_args} ${BENCHMARK_ARGS}"
    fi

    # ---------- 收集远端机器信息 ----------
    info "收集远端机器信息..."
    local remote_hostname remote_uname remote_cpu remote_mem
    remote_hostname="$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_IP}" \
        "hostname 2>/dev/null || echo 'n/a'" 2>/dev/null)"
    remote_uname="$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_IP}" \
        "uname -a 2>/dev/null || echo 'n/a'" 2>/dev/null)"
    remote_cpu="$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_IP}" \
        "cat /proc/cpuinfo 2>/dev/null | grep -m1 'model name' | cut -d: -f2 | xargs || lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2 | xargs || echo 'n/a'" 2>/dev/null)"
    remote_mem="$(sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        -p "${SSH_PORT}" "${SSH_USER}@${SSH_IP}" \
        "free -h 2>/dev/null | grep Mem | awk '{print \$2}' || echo 'n/a'" 2>/dev/null)"

    success "远端信息收集完成"

    # ---------- 本地模型 MD5 ----------
    local local_model_md5
    local_model_md5="$(md5sum "${BENCHMARK_PATH}" 2>/dev/null | cut -d' ' -f1 || echo 'n/a')"

    # ---------- 写入报告头 ----------
    {
        echo "==========================================================="
        echo "  benchmark_model 测试报告"
        echo "==========================================================="
        echo "测试时间:     $(date '+%Y-%m-%d %H:%M:%S')"
        echo "本地主机:     ${local_host}"
        echo ""
        echo "--- 远端机器信息 ---"
        echo "IP 地址:      ${SSH_IP}"
        echo "SSH 端口:     ${SSH_PORT}"
        echo "用户名:       ${SSH_USER}"
        echo "主机名:       ${remote_hostname}"
        echo "系统信息:     ${remote_uname}"
        echo "CPU 型号:     ${remote_cpu}"
        echo "内存总量:     ${remote_mem}"
        echo ""
        echo "--- 运行参数 ---"
        echo "构建目录:     ${BUILD_DIR}"
        echo "二进制路径:   ${remote_bin_path}"
        echo "模型文件:     ${REMOTE_MODEL_PATH}"
        echo "模型 MD5:     ${local_model_md5}"
        echo "运行参数:     ${full_args}"
        echo ""
        echo "--- benchmark 原始输出 ---"
        echo ""
    } > "${result_file}"

    # ---------- 远端执行并捕获输出 ----------
    info "在远端执行 benchmark_model ..."
    echo "============================================="

    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no \
        -p "${SSH_PORT}" \
        "${SSH_USER}@${SSH_IP}" \
        "chmod +x ${remote_bin_path} && ${remote_bin_path} ${full_args} 2>&1" 2>/dev/null | tee -a "${result_file}"

    local bench_exit_code=${PIPESTATUS[0]}

    echo "============================================="

    # ---------- 写入报告尾 ----------
    {
        echo ""
        echo "--- 完成状态 ---"
        echo "结束时间:     $(date '+%Y-%m-%d %H:%M:%S')"
        echo "退出码:       ${bench_exit_code}"
        if [[ ${bench_exit_code} -eq 0 ]]; then
            echo "状态:         成功"
        else
            echo "状态:         测试异常退出（详见上述输出）"
        fi
    } >> "${result_file}"

    success "远端执行完成"
    success "测试结果已保存: ${result_file}"
}

# ========================== 主流程 ==========================
main() {
    # 优先解析命令行参数，--build-dir 可覆盖环境变量中的 BUILD_DIR
    parse_args "$@"

    echo "============================================="
    echo "   benchmark_model 部署 -> 执行工具"
    echo "============================================="
    echo ""

    load_config
    validate_and_fill_config
    # 验证 BUILD_DIR：应用命令行参数覆盖、路径解析、目录有效性检查
    validate_build_dir
    check_dependencies
    test_ssh_connection
    validate_and_input_benchmark_bin
    validate_and_sync_model
    deploy_and_run

    echo ""
    success "全部完成！"
}

main "$@"