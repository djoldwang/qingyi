# 第三方服务与许可证

本说明适用于轻译 1.0.4 的源码、应用程序和随附资源。

## 项目许可

Copyright (c) 2026 Qingyi contributors。

轻译的当前代码、资源与文档采用 GNU GPL 第 3 版（GPL-3.0-only）。正式发布时，安装包与对应版本的完整源码、资源和构建脚本一同提供。此前已按 MIT 取得的副本继续享有原许可权利。第三方翻译内容、商标及在线服务的使用条件由相应权利人确定。[项目许可证](LICENSE) · [历史版本许可说明](RELICENSING.md)

## 哪些内容会发送给谁

| 操作 | 处理位置和发送内容 |
| --- | --- |
| 选中文字或截图 | 轻译在 Mac 上检测选区，截图使用系统 Vision 框架在本机识字。开始翻译时，服务收到识别出的文字，截图图像留在本机。 |
| 翻译或查词 | 原文发给已启用的翻译来源。有道和 Google 默认开启，可在设置中分别关闭。AI 翻译启用且有可用模型时，所选 AI 服务收到原文和翻译提示词。启动或启用有道时会预热网络连接，此步骤不包含原文。 |
| 中文润色、自定义 AI 动作 | 所选 AI 服务收到选中的文字和该动作的提示词。切换到另一个动作或模型时，会将最初选中的完整文字发送给新选定的服务。 |
| 优化提示词 | 点击优化后，当前动作的模型收到正在编辑的提示词和优化要求。预览、采用和撤销在本机进行。 |
| 配置 AI 服务 | 登录 ChatGPT 时由浏览器向 OpenAI 授权，轻译调用 Responses API，使用该连接获准的额度。自定义 API 按用户配置的地址和协议发送凭据及相应请求，接收方可以是用户选定的网关。获取模型列表会访问所填地址。 |

登录凭据和保存的 API 密钥使用 macOS 钥匙串。服务选择、模型、动作和提示词设置保存在本机。收件服务对请求的处理和保留服从其适用条款及账户设置。ChatGPT 连接显式请求 `store: false`，不同自定义服务的能力和数据政策各异。[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source) · [OpenAI 隐私政策](https://openai.com/policies/privacy-policy/)

## 当前翻译服务实现

| 服务 | 请求与解析方式 |
| --- | --- |
| 有道普通翻译 | 原生请求网页使用的 jsonapi_s 接口，核对完整原文回显。长文按自然段及必要的句子边界组织，最多六路并发，保护代码、网址、版本与标记，再按原顺序显示。 |
| 有道查词 | 原生请求 jsonapi_s 的 ec 词典字段，核对词头并提取音标、词性与释义；解析变化时保留公开移动词条页回退。 |
| 有道原生回退 | JSON 协议或完整性校验失败时，保留移动表单及原生整篇网页协议。整篇协议使用 CryptoKit／CommonCrypto 签名与解密，核对全文；验证失败时可回退匿名流式协议。 |
| 有道页面回退 | 使用 WKWebView 加载对应公开页面，通过轻译的 DOM 交互代码读取本次结果。 |
| Google 翻译与查词 | 向 translate.google.com 或 translate.googleapis.com 请求免签名 JSON，原生解析译文、音标、词性与释义。主路径失败时最多请求一次备用路径。 |

App 不随附有道或 Google 网站的 JavaScript 文件、第三方翻译 SDK 或第三方翻译客户端库。页面回退时，WKWebView 会从服务网站加载页面及其资源。网络、加密和页面显示使用 macOS SDK 提供的框架。

## 服务协议参考

有道网页协议核对其公开前端 translation-website 1.1.6 的 [app.14248eec.js](https://shared.ydstatic.com/dict/translation-website/1.1.6/js/app.14248eec.js) 中 87797／3557 模块及 [textTranslate.7037008a.js](https://shared.ydstatic.com/dict/translation-website/1.1.6/js/textTranslate.7037008a.js)。这里只记录互操作所需的协议信息，网站代码不随 App 分发。

有道快速请求核对 app.14248eec.js 中 getDictTranslateResult 的请求字段与摘要规则，独立实现位于 Sources/YoudaoNativeRequest.swift。自然段划分、并发协调及代码标识保护由轻译自行实现。公开接口的完整输入上限通过实际回显校验，较长输入不会直接作为完整结果使用。

有道匿名流式通道使用 dict-trans.youdao.com 的公开网页协议，核对其匿名会话参数、字段摘要规则及 begin／message／end 事件，原生实现位于 Sources/YoudaoStreamingTranslation.swift。匿名会话不写入用户钥匙串。

Google 主备路径使用公开网页翻译服务的 JSON 响应，查词请求按服务实际返回内容展示字段。

网页接口和开发者 API 有不同的使用条件。当前有道、Google 网页通道用于第三方客户端公开分发的授权范围仍待确认。网页、协议和服务方的限流策略可能变化。开发者接入可查阅双方的正式 API 文档。[有道词典条款](https://c.youdao.com/dict/law/youdao_dict_service.html) · [有道翻译条款](https://c.youdao.com/dict/law/youdaofanyi_pc_service.html) · [有道智云文本翻译 API](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html) · [Google 条款](https://policies.google.com/terms) · [Google 隐私政策](https://policies.google.com/privacy) · [Google Cloud Translation](https://cloud.google.com/translate/docs/overview)
