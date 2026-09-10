# Codex Quota

macOS 菜单栏额度监测器，带悬停展开的置顶额度胶囊。

**首次安装请阅读 [完整安装指南](INSTALL.md)**，包含环境准备、安装验证、升级、卸载和常见问题。

![Codex Quota 胶囊与双额度详情面板](docs/images/codex-quota-preview.png)

## 使用

右键菜单或面板“…”菜单中可设置 **外观 / Appearance**（跟随系统、Light、Dark）、**语言 / Language**（中文、English）和 **时区 / Time zone**。选择后面板立即更新，无需重启，设置会保存。外观默认跟随系统；时区默认跟随系统，也可按地区选择 IANA 时区（如 `Asia/Shanghai`、`America/Los_Angeles` 或 `UTC`）。

远程 `codex_reset` 的无时区文本始终按北京时间解析，再转换为所选时区显示；额度重置时间和更新时间也采用所选时区。时区转换包含夏令时和跨日处理，倒计时表示同一实际时间点的剩余时长。

- 默认仅显示 **96 × 34 pt** 的胶囊：剩余百分比与细进度环。
- 鼠标悬停约 0.1 秒后平滑展开详情；移开约 0.32 秒后平滑收起。
- 详情为 280 pt 宽：各额度周期、进度条、重置日期/倒计时、更新时间和刷新按钮。
- 详情显示“下次福利重置（预测）”和两位小数的置信度；点击置信度后的眼睛按钮，通过气泡查看完整预测理由。长内容可滚动、选择和复制，点击外部或按 Esc 关闭气泡。时间来自远程配置，并显示本地倒计时。
- 福利预测在程序启动时立即读取，此后独立每 10 分钟更新；手动刷新或电脑唤醒时也会读取，不受额度自动刷新间隔设置影响。
- 可拖动胶囊调整位置；自动选择左右展开方向，限制在屏幕内。位置与置顶设置会保存。
- 详情顶部的图钉切换置顶，“…”打开菜单，“×”隐藏整个胶囊。
- 菜单栏显示 `Codex 36%`。左键显示/隐藏胶囊，右键打开菜单。
- 每 60 秒更新，电脑唤醒时也会更新。请求失败保留上次数据并显示警告，不会把缺失数据当作 0。
- 如果返回多个额度周期，菜单栏和胶囊显示剩余比例最低的一个；展开后同时展示。
- 面板支持浅色和深色外观，默认跟随系统；两套外观都有独立的背景、边框、文字、进度条和状态颜色。数字和警告不依赖颜色区分。
- app 使用深色“额度环 + Codex 火花”图标，在 Finder、Dock 和应用程序文件夹中保持一致。

图标源文件是 `icon.svg`，构建时由 `IconRenderer.swift` 渲染为 app 内的 `Contents/Resources/AppIcon.png`。
- 展开使用平滑伸展和内容错峰浮现，边线到达最终位置后不会回弹；收起时反向聚拢。开启系统“减少动态效果”时即时切换；快速移入/移出不会留下半展开状态。

## 启动和退出

安装位置：`~/Applications/Codex Quota.app`。

- 双击 app 或使用 `open "$HOME/Applications/Codex Quota.app"` 手动启动。
- 启动或退出 Codex 不会自动启动、关闭或重新打开额度工具。
- 安装脚本会移除旧版本创建的自动启动监听器。
- 从菜单选择“退出 Codex Quota”即可单独关闭。

## 构建与验证

需要 Command Line Tools、Python 3.8+，以及已登录且能返回额度信息的 Codex。

当前现成 app 已验证的环境是 Apple Silicon + macOS 26，二进制最低系统版本为 26.0；`Info.plist` 中的 13.0 声明不代表现成构建兼容旧系统。其他系统或 Intel Mac 请在目标机器上从源码构建，兼容性尚未验证，详见安装指南。

```sh
zsh build.sh
python3 install.py
```

安装前验证构建签名，替换失败时尝试恢复原安装。应用直接使用本机 Codex App Server 的只读额度查询接口；不启动模型对话，不自动消耗重置券，也不读取或保存登录令牌。福利重置预测读取 [远程纯文本配置](https://config-center-1412625299.cos.ap-guangzhou.myqcloud.com/config/test/codex_reset)：第一行是时间，第二行是 `0.00–1.00` 的置信度，第三行起是理由。时间支持 `yyyy-MM-dd HH:mm:ss`、ISO 8601 和 Unix 时间戳；无时区格式按 `Asia/Shanghai` 解析。旧的一行时间格式仍兼容；请求失败时保留上次成功获取的完整预测。

```sh
'Codex Quota.app/Contents/MacOS/CodexQuota' --self-test
'Codex Quota.app/Contents/MacOS/CodexQuota' --smoke-test
'Codex Quota.app/Contents/MacOS/CodexQuota' --render-previews qa/hover-previews
```

`--smoke-test` 真实查询失败时返回非零状态；不会保存测试窗口位置。
`--render-previews` 仅渲染应用自身视图，不读取屏幕、不查询账户，检查单行文字宽度、控件边界和刷新按钮状态。

## 源码

- `main.swift`：额度连接、菜单栏、悬停行为、偏好设置与刷新。
- `QuotaView.swift`：胶囊与详情面板。
- `HoverSurface.swift` / `HoverGeometry.swift`：鼠标跟踪、即时布局容器和屏幕边界布局。
- `Preview.swift`：离线视觉预览和布局检查。
- `icon.svg` / `IconRenderer.swift`：app 图标源图和 macOS 渲染器。
- `install.py`：安装、升级和失败恢复。

检查记录见 [qa/REVIEW.md](qa/REVIEW.md)。
接口文档：https://learn.chatgpt.com/docs/app-server#auth-endpoints


刷新间隔：点击详情面板的“…” → “刷新间隔…”，可设置 10–3600 秒，默认 60 秒。保存后立即刷新一次并重设定时器；设置会保留到下次启动。手动刷新、唤醒刷新和服务端额度更新通知仍可提前触发查询。

## 许可证

本项目采用 [MIT License](LICENSE)。
