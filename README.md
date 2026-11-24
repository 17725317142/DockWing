# DockWing

极致轻量的 Mac 程序坞与窗口小助手。  
**核心仅 174 KB · 内存 ~11 MB · 空闲 CPU 0% · 零联网 · 无需录屏权限**

## 功能（均可单独开关）

1. **点图标最小化**：再点一次前台软件的程序坞图标自动缩小，再点还原。
2. **悬停多窗口切页**：同一软件打开 ≥ 2 个窗口时，悬停图标直接点选切换或点 `×` 关单窗（单窗不打扰）。
3. **关最后窗口退出**：点左上角红叉关掉最后一个窗口时，自动温和退出软件释放内存（保护未保存提示与访达，可选支持 `⌘W`）。
4. **刘海 0.15s 切桌面**：鼠标滑到 MacBook 刘海停留 0.15 秒，自动打开桌面切换（等同 `⌃Control + ↑`，拖拽窗口不误触）。

## 怎么用（3 步）

1. 在右侧 **[Releases](../../releases)** 下载 `DockWing-v1.0.0-macOS-arm64.zip` 解压，把 `DockWing.app` 拖进 **应用程序** 并打开。
   * 首次若提示“无法验证开发者”，去 **系统设置 → 隐私与安全性** 底部点 **仍要打开**（或终端运行 `xattr -cr /Applications/DockWing.app`）。
2. 点顶部菜单栏的 DockWing 图标 → **点此开启系统权限** → 在 **辅助功能 / 设备控制和数据访问** 中打开 `DockWing.app` 开关（2 秒自动生效）。
3. 在顶部菜单栏按需勾选开关和 **开机自启** 即可。

> **卸载**：取消「开机自启」→ 退出 → 将 `DockWing.app` 拖进废纸篓。

## 优劣势对比

### 优势
* **极低占用**：纯原生 AppKit，约 **11 MB** 内存、**0%** 空闲 CPU，8GB 内存 MacBook 毫无压力。
* **隐私干净**：不申请录屏权限、完全离线、无广告无统计。
* **稳定不失效**：单进程无阻塞监听，自带超时与休眠自动重连。
* **零入侵**：无需关闭 SIP，不改系统与其他软件文件。

### 劣势
* **无实时画面预览**：悬停仅显示窗口标题列表（为了省内存、省电且不申请录屏权限）。
* **无商业签名**：个人开源未购 Apple 年费公证，首次打开需手动点一次「仍要打开」。
* **无单独应用白名单**：关最后窗口自动退出作用于所有常规软件（保护访达）；想留后台的软件请用 `⌘H` 隐藏或点图标最小化。
* **系统与硬件限制**：需 macOS 14+；刘海切桌面仅支持刘海屏 MacBook；预编译包为 M 芯片，Intel Mac 可用下方命令自编译。

## 附：让原生程序坞「秒弹」（无需插件）

```bash
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.15
killall Dock
```

## 源码自编译

```bash
git clone https://github.com/17725317142/DockWing.git
cd DockWing && ./Scripts/build.sh
```

[MIT License](LICENSE)
