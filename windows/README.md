# Clawd 伴随 · Windows 版（测试版）

让 Claude 的像素小螃蟹 Clawd 蹲在**小狼毫（Weasel）**的候选框上，跟着光标爬。功能和 macOS 版相同：Claude 风格主题、全套动画、万圣节女巫装、开机自启、一键安装和卸载。

> 这是第一个 Windows 版本，还在测试中。遇到问题欢迎提 issue，附上 `%LOCALAPPDATA%\ClawdCompanion\live.log` 的内容会很有帮助。

## 需要什么

- Windows 10 或 11
- [小狼毫](https://rime.im) 0.15 以上（在 0.17 系列上开发）和 [雾凇拼音](https://github.com/iDvel/rime-ice)

## 安装

1. 下载 `Clawd-windows.zip`，解压出 `Clawd.exe`，放到一个固定的位置（比如 `D:\Tools\Clawd\`）。开机自启会记住这个位置，之后别再移动它。
2. 双击 `Clawd.exe`。如果 Windows 提示「已保护你的电脑」，点「更多信息 › 仍要运行」（这个程序没有付费的代码签名）。
3. 在弹出的设置窗口里点 **「安装到小狼毫」**，等小狼毫重新部署完，随便打几个字就能看到 Clawd。

之后想回到设置窗口：双击右下角通知区域里的小 Clawd 图标，或者再打开一次 `Clawd.exe`。

## 如果 Clawd 没有正好站在候选框上

不同版本的小狼毫，候选框窗口四周留的空白可能不一样。在设置窗口的「位置微调」里调「左右」「上下」的数值就行，单位是像素（按 100% 缩放计算），调完立刻生效。

## 自己编译

不需要安装任何东西，Windows 自带编译器：

```bat
windows\build.bat
```

产物在 `windows\dist\Clawd.exe`。小狼毫主题和 `clawd.lua` 都打包在 exe 里。

检查造型和 macOS 版是否逐像素一致：

```bat
windows\dist\Clawd.exe --dump-sprites sprites.win.txt
fc sprites.win.txt windows\sprites.ref.txt
windows\dist\Clawd.exe --render-sheet sprites.png
```

## 卸载

1. 在设置窗口点「卸载」：删除小螃蟹脚本，还原原来的主题。
2. 关掉「开机自动启动」，在托盘菜单里点「退出 Clawd」，删掉 `Clawd.exe`。
3. 设置保存在注册表 `HKEY_CURRENT_USER\Software\ClawdCompanion`，可以一起删掉。
