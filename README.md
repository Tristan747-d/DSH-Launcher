# DSH Launcher

把 **DeepSeek Harness** 的 Web GUI 包成一个原生 macOS app：打开 App = 跑
`dsh web`，但**不弹出浏览器**——界面直接显示在 App 窗口里。

```
之前：打开终端 → 输入 dsh web → 浏览器自己弹出来 → 多一个窗口要管
现在：双击 DSH Launcher.app → 完事
```

---

## 一、安装

```sh
git clone https://github.com/Tristan747-d/DSH-Launcher.git
cd DSH-Launcher
./build-app.sh --install        # 编译 + 签名 + 安装到 ~/Applications
open "~/Applications/DSH Launcher.app"
```

前置：Xcode 命令行工具（`swiftc`）与一张 Apple Development 证书。
证书 ID 可以用环境变量覆盖：`DSH_LAUNCHER_SIGN_ID=... ./build-app.sh --install`。

装好之后双击即可，不需要终端，也不需要再管 `dsh web`。

---

## 二、它到底做了什么

App 启动时：

1. 找到 `dsh` 可执行文件（`~/.local/bin/dsh` → Homebrew → `/usr/local/bin`）；
2. 以子进程方式启动 `dsh web --no-open --port <空闲端口>`；
3. 从子进程 **stdout** 里读出那一行
   `dsh web: http://127.0.0.1:<port>/?token=…`；
4. 把这个带 token 的 URL 载入内置的 `WKWebView`，界面就出现在窗口里。

`--no-open` 是关键：它让 DSH 不要弹出浏览器。我们只借它的 stdout。

### token 与 cookie（为什么第二次启动更快）

带 token 访问首页时，DSH 会 30 天有效的 `dsh-auth-…` cookie 并 303 跳到干净的 `/`。
Launcher 用一个**固定 ID 的 `WKWebsiteDataStore`** 持久保存它，所以：

- 第一次启动：用 token 换 cookie；
- 之后启动：cookie 还在，直接就能打开。

### 已经在跑的 3080 怎么办

如果 3080 上已经有 DSH（比如你自己在终端开的），Launcher 会：

1. 探测它是不是 DSH（`GET /` 是否返回 401/303/200）；
2. 拿自己保存的 cookie 去试一次——**通过才接管**；
3. 通不过（别人的进程、token 不同）就自己在 3081 起一个，
   **绝不动你终端里的那个**。

这是刻意的：终端里那个 server 的 token 是进程级的，Launcher 拿不到，
所以它没有资格假设自己能用。宁多起一个，也不抢你的会话。

---

## 三、样式：抄的是 Codex 桌面版

用户要求「按 Codex 的样式封装」，所以窗口结构对着 Codex macOS 版做：

| 特征 | 实现 |
|---|---|
| 没有可见标题栏 | `.fullSizeContentView` + `titleVisibility = .hidden` |
| 红黄绿灯浮在内容上 | `titlebarAppearsTransparent = true` |
| 页面占满其余全部像素 | 页面自带侧边栏/输入框，原生不再画任何 chrome |
| 深色底，加载不闪白 | `underPageBackgroundColor` 与 DSH 背景同色 |
| 拖拽 / 双击缩放 | 顶部 30pt 原生拖动条（见下） |
| 完整菜单栏 | 编辑（⌘C/⌘V/⌘A）、显示、窗口菜单 |

### 为什么是 30pt 原生条，而不是 CSS 拖拽区

常见做法是给页面顶部加 `-webkit-app-region: drag`，**但那是 Chromium 的属性，
WKWebView 不实现它**。另一个诱人的做法是 `isMovableByWindowBackground = true`，
代价是页面里所有文本选择都会变成拖窗口，非常难用。

所以这里放了一条 30pt 的原生视图，正好压在红黄绿灯那条带子上：
AppKit 自动让它拖窗口、双击缩放，不需要改 DSH 一行 CSS。

---

## 四、设置

配置文件是 JSON，第一次启动就会生成：

```
~/Library/Application Support/DSHLauncher/settings.json
```

| 字段 | 默认 | 含义 |
|---|---|---|
| `preferredPort` | `3080` | 首选端口，和 DSH 默认一致 |
| `adoptExistingServer` | `true` | 3080 上已有 DSH 且 cookie 可用时直接接管 |
| `stopServerOnQuit` | `true` | 退出 App 时关掉**它自己启动的** server |
| `externalLinksInBrowser` | `true` | 外部链接交给系统浏览器，不在窗口里打开 |
| `windowWidth` / `windowHeight` | `1280` / `880` | 首次窗口尺寸 |

`stopServerOnQuit` 只对 Launcher 自己拉起的子进程生效。
终端里那个、或只是被接管的那个，永远不会被它关掉。

日志（排查启动失败用）：

```
~/Library/Application Support/DSHLauncher/launcher.log    # Launcher 的决策
~/Library/Application Support/DSHLauncher/dsh-web.log     # server 的 stdout/stderr
```

菜单里还有「显示 → 复制带 token 的地址」：万一某个功能在 WKWebView 里表现异常，
可以把这个 URL 粘到真浏览器里对照。

---

## 五、源码结构

```
Sources/DSHLauncher/
  main.swift                 入口 + 菜单栏
  MainWindowController.swift 窗口、WKWebView、导航策略、JS 弹窗
  ServerController.swift     找 dsh、起进程、读 stdout、探测/接管、退出清理
  Preferences.swift          JSON 设置 + 日志
Resources/Info.plist         bundle 元数据（含 NSAllowsLocalNetworking）
Assets/icon-1024.png         图标母版，其余尺寸由 build-app.sh 用 sips 派生
build-app.sh                 编译 + 图标 + 签名 + 安装
```

### 两个必须知道的构建坑

1. **必须在 iCloud 之外 staging 再签名。** 本机 `~/Desktop` 是指向
   `~/Library/Mobile Documents` 的软链接，iCloud 会在 `xattr -cr` 和
   `codesign` 之间重新贴上 `com.apple.FinderInfo`，导致签名报
   "resource fork, Finder information, or similar detritus not allowed"。
   `build-app.sh` 因此在 `/tmp` 组装。
2. **全机只允许一份这个 bundle id。** LaunchServices 按 bundle id 解析到唯一
   位置，多一份构建产物会让解析变歧义。脚本会清掉 `build/` 和桌面上的副本。

---

## 六、这个项目为什么成立：DSH 完全开源，一切可定制

这层壳之所以能这么薄，是因为 DSH 本身开放：

- `dsh web` 把监听地址与 token 打到 stdout —— 所以不需要 fork 它、不需要私有
  IPC，读一行标准输出就够了；
- 认证走标准 cookie，所以一个普通的 `WKWebsiteDataStore` 就能持久化会话；
- 前端已经是完整应用（PWA manifest 里就是 `display: fullscreen`，自带侧边栏、
  顶栏、输入器）—— 所以原生侧**什么都不用画**，画了反而打架。

也就是说：需要改 DSH 行为时，改 DSH 本身（profile / 插件 / patch layer），
而不是在外面糊一层模拟。Launcher 只负责「起服务 + 显示」，不假装自己是 DSH。

已知与定制相关的面：`~/.dsh/profiles/web/cordis.patch.yml`（profile 补丁层）、
`~/.dsh/settings.yaml`（主题/皮肤/模型）、以及 client 插件
（如 `dsh-computer-use-panel` 那样注册侧边栏条目）。

---

## 七、和 Computer Use 的关系

`dsh-cua` 的实时画面有一个自录防护：拒绝录制「正在显示 DSH 界面」的窗口，
否则会出现窗口套娃。Launcher 的 bundle id（`com.tristan.dsh.launcher`）已加进
它的 `harnessOwningBundleIDs`，端口检测也从写死的 3080 放宽到
`dshPortBand`（3080–3099），因为 Launcher 会在 3080 被占时往这个带里走。

它**没有**粗暴地拒绝「所有 loopback」——模型流式看你自己的
`127.0.0.1:3000` 开发服务器是正当需求，不能被误伤。

---

## License

MIT
