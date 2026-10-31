<div align="center">

<img src="docs/icon.png" width="112" alt="Clawd 图标">

# rime-clawd

**让 Claude 的像素小螃蟹 Clawd 住进你的 Rime 输入法**

Claude 风格的候选框主题 + 一个蹲在候选框上、跟着光标爬的像素小螃蟹

macOS（鼠须管 Squirrel）· Windows（小狼毫 Weasel，测试版）

<img src="docs/demo-classic.gif" width="400" alt="经典 Clawd 演示">&nbsp;&nbsp;<img src="docs/demo-witch.gif" width="400" alt="万圣节女巫 Clawd 演示">

<sub>左：经典 Clawd　右：万圣节限定女巫装（10/24 – 11/2 自动换装）</sub>

</div>

---

## 功能

- **Claude 风格主题**：象牙白纸面、白色输入栏、Claude 橙选中胶囊，浅色 / 深色自动切换，带一点点毛玻璃。
- **会动的 Clawd**：站在候选框上沿、正对光标。你每打一个字母，它就横着爬一步。
- **一键安装**：主题和脚本都打包在 App 里，点一下「安装到鼠须管」就配置好。原配置自动备份，卸载时还原。
- **开机自启、几乎不耗电**：只在你打字时动画，空闲时 CPU 占用为 0。
- **Apple 芯片和 Intel Mac 都能用**（通用二进制，macOS 13+）。
- **也有 Windows 版**（小狼毫，测试版）：单个 exe，用 Windows 自带的编译器就能编译，见 [windows/README.md](windows/README.md)。

<p align="center"><img src="docs/panel.png" width="560" alt="真实候选框效果"></p>

### Clawd 的动作

| 你在做什么 | Clawd 在做什么 |
|---|---|
| 打字 | 横着爬到光标上方，迈腿、眼睛朝前看 |
| 停下来挑候选 | 东张西望、眨眼、钳子一沉一浮地「呼吸」 |
| 按退格 | 头顶冒出「!」，吓得往上一弹 |
| 打出 `claude` | 双钳轮流挥舞，冒小火花 |
| 上屏 | 举起双钳跳一下，撒一圈 ✻ 火花 |
| 编码很长 | 冒汗 |
| 万圣节前后 | 戴上女巫帽骑扫帚，身后拖着一串火花 |

<p align="center"><img src="docs/sprites.png" width="640" alt="全部造型"></p>

## 安装

### Windows（小狼毫）

见 [windows/README.md](windows/README.md)。造型和 macOS 版逐像素一致，每次构建都会自动比对。

### macOS（鼠须管）

**前提**：已经装好 [鼠须管](https://rime.im)（1.0 以上，在 1.1.2 上测试）和 [雾凇拼音](https://github.com/iDvel/rime-ice)。

1. 到 [Releases](../../releases) 下载 `Clawd-x.y.z.dmg`，把 **Clawd** 拖进「应用程序」。
2. 第一次打开时，macOS 会提示「无法验证开发者」（这个 App 没有付费的 Apple 开发者签名）。处理方法二选一：
   - 打开「系统设置 › 隐私与安全性」，在页面下方点「仍要打开」；或者
   - 在终端执行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/Clawd.app
     ```
3. 打开后会弹出设置窗口：点 **「安装到鼠须管」**，等鼠须管重新部署完，随便打几个字就能看到 Clawd。

<p align="center"><img src="docs/settings.png" width="380" alt="设置窗口"></p>

之后想回到设置窗口：在启动台或聚焦搜索（⌘ 空格）里打开「Clawd」，或者点菜单栏上的小 Clawd 图标。

> 菜单栏图标太多时，macOS 会把新图标收进菜单栏左侧的「»」里。点开「»」就能找到它。

## 使用其他输入方案

自动安装目前只会给**雾凇拼音**（`rime_ice`）挂上小螃蟹脚本。用其他方案（比如朙月拼音 `luna_pinyin`）的话，先在设置里点一次「安装到鼠须管」装好主题和 `lua/clawd.lua`，然后在 `~/Library/Rime/<方案名>.custom.yaml` 的 `patch:` 下面加上这几行（见 [`Resources/rime/schema.custom.snippet.yaml`](Resources/rime/schema.custom.snippet.yaml)），再重新部署：

```yaml
patch:
  "engine/translators/+":
    - lua_translator@*clawd
  clawd:
    style: companion   # companion | clawd | crab | emoji | off
    sparkle: true      # 光标后面的 ✻ 火花
```

如果文件里已经有 `"engine/translators/+"`，就别再写一个新键了，直接在它的列表里加一行 `- lua_translator@*clawd`。

`clawd/style` 的几种取值：

| 取值 | 效果 |
|---|---|
| `companion`（默认） | 像素 Clawd 由 Clawd.app 画在候选框上沿 |
| `clawd` | 不装 App 也能用：用方块字符在拼音下方拼出两行高的 Clawd |
| `crab` | 单行颜文字 `V(•ᴗ•)V` |
| `emoji` | 🦀 |
| `off` | 关闭 |

## 自定义主题

主题文件是 `~/Library/Rime/squirrel.custom.yaml`，里面每个颜色都写了注释。注意鼠须管的颜色写法是 `0xAABBGGRR`（BGR 顺序，AA 是不透明度）。比如想要更「玻璃」，把 `back_color` 开头的 `F2` 调小（比如 `C0`）。改完点「重新部署」。

## 工作原理

鼠须管的候选框只能显示文字，画不了图片，所以 Clawd 由一个独立的小 App 来画：

```
按键 ─▶ librime ─▶ lua/clawd.lua ──写入──▶ ~/Library/Caches/ClawdCompanion/state
                       │                                   │（文件变化通知）
                       └─ 在光标后放 ✻ 火花                  ▼
                                                    Clawd.app
                                    ├─ 找到鼠须管候选框窗口的位置（CGWindowList）
                                    ├─ 用和候选框相同的字体量出光标横坐标
                                    └─ 在一个透明、点击穿透的悬浮窗里逐像素画出 Clawd
```

- Clawd 的造型由代码一格一格画出来（本体 24×16 像素），不用图片素材，所以在 Retina 屏上始终清晰，每个部位都能单独动。
- 只有你在打字时才以 60 帧刷新；不打字时不跑任何定时器。
- 排查问题可以看 `~/Library/Caches/ClawdCompanion/live.log`。

## 从源码构建

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
./build.sh            # 构建 build/Clawd.app（通用二进制）
./build.sh install    # 构建并安装到 ~/Applications，然后启动
./build.sh dist       # 打包 dist/Clawd-x.y.z.dmg 和 .zip
./build.sh demo       # 重新录制 docs/ 里的演示 GIF（需要 python3 + Pillow）
```

## 卸载

1. 打开 Clawd 的设置窗口，点「卸载」：删除小螃蟹脚本、还原原来的主题。
2. 关掉「开机自动启动」，点「退出 Clawd」，再把 Clawd.app 拖进废纸篓。

## 已知限制

- 候选框上方就是你正在输入的那一行，Clawd 会挡住光标右边一小块。可以在设置里调成「小」，或者关掉。
- 为了让输入栏显示在候选框里，主题使用 `inline_preedit: false`：拼音显示在候选框顶部，不直接显示在文本框里。
- 自动配置只支持雾凇拼音；其他方案请按上面的方法手动添加几行。

## 声明

这是一个**非官方的粉丝项目**，与 Anthropic 没有任何关联，也没有得到 Anthropic 的认可。Claude 和 Clawd 是 Anthropic 的商标和角色形象，版权归 Anthropic 所有；本项目中的 Clawd 像素造型是照官方形象重绘的同人作品，仅供个人学习和娱乐。

代码以 [MIT 许可证](LICENSE) 开源（不包括 Clawd 角色形象本身）。

感谢 [Rime / 鼠须管](https://github.com/rime/squirrel)、[librime-lua](https://github.com/hchunhui/librime-lua) 和 [雾凇拼音](https://github.com/iDvel/rime-ice)。
