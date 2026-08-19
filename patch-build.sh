#!/usr/bin/env bash

# 遇到命令失败、使用未定义变量或管道中的命令失败时立即退出，避免在异常状态下继续修改源码。
set -euo pipefail

# 获取脚本所在目录的绝对路径，确保从任意工作目录执行脚本时都能正确定位文件。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 确定 OpenWrt 源码目录：优先使用第一个命令行参数，其次使用 WORKDIR，最后默认使用 openwrt。
OPENWRT_DIR="${1:-${SCRIPT_DIR}/${WORKDIR:-openwrt}}"

# 如果传入的是相对路径，则将其转换为相对于脚本目录的绝对路径。
if [[ "${OPENWRT_DIR}" != /* ]]; then
  OPENWRT_DIR="${SCRIPT_DIR}/${OPENWRT_DIR}"
fi

# 在执行补丁前确认 OpenWrt 源码目录存在，防止修改错误的位置。
if [[ ! -d "${OPENWRT_DIR}" ]]; then
  echo "OpenWrt source directory not found: ${OPENWRT_DIR}" >&2
  exit 1
fi

# 修补 ripgrep 的构建配置，禁用 LTO 以避免链接阶段出现构建问题。
patch_ripgrep() {
  # 定位 ripgrep 软件包的 Makefile。
  local makefile="${OPENWRT_DIR}/feeds/packages/utils/ripgrep/Makefile"

  # 确认 Makefile 存在；如果 feeds 尚未安装或路径发生变化，则立即报错。
  if [[ ! -f "${makefile}" ]]; then
    echo "Makefile not found: ${makefile}" >&2
    exit 1
  fi

  # 确认 package.mk 的引入位置存在，以便把构建标志插入到正确位置。
  if ! grep -qFx 'include $(INCLUDE_DIR)/package.mk' "${makefile}"; then
    echo "package.mk include not found: ${makefile}" >&2
    exit 1
  fi

  # 先删除已有的相同配置，使脚本可以重复执行而不会产生重复内容。
  sed -i '/^PKG_BUILD_FLAGS:=no-lto$/d' "${makefile}"

  # 在引入 package.mk 之前加入 no-lto 构建标志。
  sed -i '/^include $(INCLUDE_DIR)\/package\.mk$/i PKG_BUILD_FLAGS:=no-lto' "${makefile}"

  # 输出修改结果及其上下文，便于在构建日志中确认补丁已正确应用。
  echo "Patched ripgrep:"
  grep -n -B1 -A1 -F 'PKG_BUILD_FLAGS:=no-lto' "${makefile}"
}

# 修补 netdata 的配置参数，关闭 Netdata Cloud 功能。
patch_netdata() {
  # 定位 netdata 软件包的 Makefile。
  local makefile="${OPENWRT_DIR}/feeds/packages/admin/netdata/Makefile"

  # 确认 Makefile 存在；如果 feeds 尚未安装或路径发生变化，则立即报错。
  if [[ ! -f "${makefile}" ]]; then
    echo "Makefile not found: ${makefile}" >&2
    exit 1
  fi

  # 确认 netdata 的 BuildPackage 定义存在，以便把配置参数插入到软件包定义之前。
  if ! grep -qFx '$(eval $(call BuildPackage,netdata))' "${makefile}"; then
    echo "BuildPackage definition not found: ${makefile}" >&2
    exit 1
  fi

  # 先删除已有的相同参数，使脚本可以重复执行而不会产生重复内容。
  sed -i '/^CONFIGURE_ARGS += --disable-cloud$/d' "${makefile}"

  # 在 BuildPackage 定义之前加入 --disable-cloud 配置参数。
  sed -i '/^\$(eval \$(call BuildPackage,netdata))$/i CONFIGURE_ARGS += --disable-cloud' "${makefile}"

  # 输出修改结果及其上下文，便于在构建日志中确认补丁已正确应用。
  echo "Patched netdata:"
  grep -n -B1 -A1 -F 'CONFIGURE_ARGS += --disable-cloud' "${makefile}"
}

# 依次应用 ripgrep 和 netdata 补丁；任一步失败都会终止脚本。
patch_ripgrep
patch_netdata
