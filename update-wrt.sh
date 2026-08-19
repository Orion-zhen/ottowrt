#!/usr/bin/env bash
set -euo pipefail

# 脚本位于 openwrt 仓库的上一级目录。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/openwrt"
REMOTE="origin"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
    echo "错误：${REPO_DIR} 不是 Git 仓库" >&2
    exit 1
fi

cd "${REPO_DIR}"

BRANCH="$(git branch --show-current)"
if [[ -z "${BRANCH}" ]]; then
    echo "错误：当前处于 detached HEAD 状态，无法确定需要更新的分支" >&2
    exit 1
fi

echo "正在更新 ${REMOTE}/${BRANCH}……"
# 注意：这会丢弃工作区修改和未推送的本地提交。
git fetch --depth=1 --no-tags "${REMOTE}" "${BRANCH}"
git reset --hard FETCH_HEAD

# 清理旧提交的引用及对象，仅保留浅克隆可见的最新提交。
git reflog expire --expire=now --all
git gc --prune=now

echo
echo "更新完成："
git log --oneline --decorate -1
echo "可见 commit 数：$(git rev-list --count HEAD)"
echo "浅克隆状态：$(git rev-parse --is-shallow-repository)"
git status --short --branch
