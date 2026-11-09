# DockRelay

DockRelay 用来处理切换 macOS 桌面空间后，鼠标已经移走、Dock 仍保持放大或挡在全屏窗口前的问题。它在菜单栏运行，可以设置为登录时启动。

[English](README.md)

## 使用

1. 安装 Xcode 命令行工具或 Xcode，从源码构建。

   ```sh
   ./build.sh
   open build/DockRelay.app
   ```

2. 在 **系统设置 → 隐私与安全** 中开启 **DockRelay**。macOS 27.2 的中文权限页叫「设备控制和数据访问」，旧版系统一般叫「辅助功能」。授权后打开 DockRelay 的菜单刷新状态。菜单提示需要输入监控时，再按系统提示授权并重新打开应用。
3. 从 Dock 点击位于另一桌面空间的 App，在切换动画中快速移开鼠标，查看菜单中的「观察到恢复」。DockRelay 补发事件后观察到 Dock 恢复，计数才会增加。
4. 日常使用时，把应用放到固定的应用程序目录再授权，并在菜单中勾选「登录时启动」。外置盘上的应用需要该磁盘在登录时可用。

构建目标为 macOS 13 及以上，应用同时包含 Apple 芯片和 Intel 版本。临时签名的本地构建重新编译后可能要再次授权。如果开关已打开但应用仍提示未授权，在同一个权限页移除旧条目，再添加当前应用。卸载时关闭「登录时启动」、退出、删除应用，并从系统设置移除授权条目。

## 工作方式

DockRelay 只监听系统送给 Dock 进程的鼠标进入和离开事件。离开事件明明发生在 Dock 内部时，可以在 Space 通知前检查。只有当前光标已离开、图标仍处于悬停状态，才尝试提前补发一次。

收到 Space 切换通知后，它会确认附近确实发生过一次离开，再在独立队列上通过辅助功能接口检查 Dock。如果原事件发生在 Dock 范围内，且检查到图标仍处于悬停状态，一次检查即可触发补发。证据较弱时，再检查一次确认。补发前会读取最新光标位置，确认它仍在 Dock 和放大图标之外。检查最早从切换通知后 25 毫秒开始，后续逐渐拉开间隔，并在重试前给 Dock 留出收回动画的时间。新一轮 Space 切换会取消旧检查。

位置判断使用当前各显示器的 Quartz 坐标和 Dock 的停靠边，覆盖底部、左侧、右侧。空闲时没有定时轮询。运行时无网络请求和第三方依赖，事件只保存在内存里。本地日志记录监听、补发和恢复状态，以及从原始离开事件和 Space 通知到观察到恢复的时间。该时间包含两次检查之间的间隔。

```sh
log stream --style compact --predicate 'subsystem == "io.github.linxitian.dockrelay"'
```

## 验证范围

`./test.sh` 检查三个停靠方向、带偏移的显示器、隐藏 Dock 落在邻屏坐标范围的情况，以及正常、卡住和交互中的判断。已在 Apple 芯片 Mac 的 macOS 27.2（26B123）上启动并验证一次日常跨 Space 恢复，使用者看到 Dock 自行恢复，菜单中的恢复计数大于零。Intel、较早 macOS、实体多屏和全屏不隐藏仍需要实际复测。

工具通过公开 API 在用户会话中补发事件，依赖 Dock 当前使用的跟踪事件格式和辅助功能结构。系统实现变化时可能需要适配。Dock 自身的永久修复需要 Apple 更新系统。

正式分发可以在构建时通过 `SIGN_IDENTITY` 选择 Developer ID Application 证书，并在发布前完成公证。参见 [Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 致谢

事件序列和补发思路来自 [LLP2333/dockUnstick](https://github.com/LLP2333/dockUnstick/tree/3e323de2116deca69a3bb8b7280c182f670b317a)。DockRelay 独立实现了监听流程、几何判断和菜单。项目采用 [MIT 许可证](LICENSE)。
