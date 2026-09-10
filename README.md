# ottowrt

ImmortalWrt 个人配置和自动构建

推荐构建步骤:

```bash
# 拉取 immortalwrt 本体
bash update-wrt.sh

# 拉取 feeds 仓库
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
cd ..

# 应用 patch
bash patch-build.sh

# 复制构建配置
cd openwrt
cp ../configs/full.config .config

# 清理构建残留
make dirclean

# 下载依赖项
make download -j16

# 开始构建
make -j32
```
