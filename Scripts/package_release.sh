#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.0.0"
ARCH="$(uname -m)"
RELEASE_ROOT="$PROJECT_DIR/release"
PACKAGE_DIR="$RELEASE_ROOT/DockWing-v${VERSION}-macOS-${ARCH}"
ZIP_PATH="$RELEASE_ROOT/DockWing-v${VERSION}-macOS-${ARCH}.zip"

# Build fresh bundle (and also update local /Applications/DockWing.app unless SKIP_INSTALL=1)
"$PROJECT_DIR/Scripts/build.sh"

rm -rf "$RELEASE_ROOT"
mkdir -p "$PACKAGE_DIR"

cp -R "$PROJECT_DIR/build/DockWing.app" "$PACKAGE_DIR/DockWing.app"
cp "$PROJECT_DIR/LICENSE" "$PACKAGE_DIR/LICENSE"

cat <<'EOF' > "$PACKAGE_DIR/使用说明.txt"
DockWing v1.0.0 — 极致轻量的 Mac 窗口小助手

【功能】
1. 点程序坞图标最小化窗口（再点还原）
2. 悬停多窗口快速切页 / 关单窗
3. 点红叉关最后窗口自动退出软件
4. 滑到刘海停 0.15s 打开桌面切换

【使用（3 步）】
1. 将 DockWing.app 拖进「应用程序」并双击打开。
   （首次若提示未验证，去 系统设置 -> 隐私与安全性 底部点「仍要打开」）
2. 点顶部菜单栏图标 -> 开启系统权限（辅助功能 / 设备控制和数据访问）。
3. 在菜单栏勾选开关和「开机自启」即可。

【卸载】取消「开机自启」-> 退出 -> 拖进废纸篓。
EOF

# Create clean distributable ZIP archive preserving macOS app bundle metadata
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ZIP_PATH"

echo ""
echo "Release folder ready: $PACKAGE_DIR"
echo "Release zip ready:    $ZIP_PATH"
ls -lh "$ZIP_PATH"
