# 素材与第三方许可

本仓库的代码与文档许可见根目录 [LICENSE](../LICENSE)。下面这些内容**不在** MIT / CC BY-SA 范围内，需要单独确认。

## 1. 角色形象

- `entry/src/main/resources/rawfile/whale/chibi.png`、`mature.png` 目前是**占位图**（浅蓝渐变 + PLACEHOLDER 字样），可以自由替换。
- 应用图标与头像（`AppScope/resources/base/media/*`、`entry/src/main/resources/base/media/{icon,icon_app,startIcon,avatar,avatar_alpha,background}.png`）同样是占位图（浅蓝底 + 「IM」字样），不含任何角色形象。
- 本项目最初使用了一套鲷鱼娘（鲸鱼娘）风格的角色设定图，形象创意来自社区开源资产库
  `https://github.com/TreapGoGo/deepseek-whale-girl`，其代码与文字内容分别使用 MIT 与 CC BY-SA 4.0，
  但**设定图本身不在该许可内**，需要单独向原作者取得授权后才能使用。
- 如果你替换成自己的立绘，请确认你有权分发它。

## 2. 音色模型

- 仓库**不包含**任何 RVC / TTS 模型权重、索引或训练数据。
- `docs/SETUP.md` 里的语音链路只是接口说明：你需要自己准备一个兼容的合成服务，并通过 `TTS_DAEMON` 指过去。
- 用真人声音、配音演员声音或角色音色训练/转换，可能涉及著作权、表演者权、人格权（声音权）以及平台规则，
  请自行取得授权，不要在公开仓库里分发这类权重。

## 3. 字体

- 仓库不再内置字体文件，界面走系统默认字体。
- 想用 Noto Sans SC：它是 SIL Open Font License 1.1 授权，可以自由使用与再分发，但**分发时必须随附 OFL 许可文本**。
  请把字体放到 `entry/src/main/resources/rawfile/fonts/`，并在同一目录放上 `OFL.txt`。

## 4. 依赖与参考资料

- `server/` 唯一运行时依赖：`ws`（WebSocket 客户端/服务端库，MIT 许可，见 `server/package-lock.json`）。
- 其余为 Node.js 内置模块；手机端为 HarmonyOS 系统 SDK / ArkUI 组件，不随仓库分发。
- 界面里「关于大肥鱼」页的文案，改写自鲸鱼娘开源资产库的说明文字
  （`https://github.com/TreapGoGo/deepseek-whale-girl`，CC BY-SA 4.0），已在该文件头部与关于页注明来源；
  如你替换成自己的设定，请一并替换这些文案。
- 沉浸光感标题栏的写法参考了华为官方文档与 `HarmonyOS_Samples` 示例的结构思路（示例代码通常为 Apache-2.0），
  本仓库为自行编写的实现，未直接复制示例源码。
- 华为推送、AGC 相关服务受华为开发者协议约束；你需要自己的开发者账号与应用。

## 5. 商标与名称

- 「大肥鱼」「HarmonyOS」「AppGallery」等名称仅作描述性使用。
- 若发布到应用市场，请确认应用名不侵犯他人商标。
