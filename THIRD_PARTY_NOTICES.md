# 第三方服务与许可证

本说明适用于轻译 1.0.3 当前源码及 App 随附资源。

## 项目许可

Copyright (c) 2026 Qingyi contributors。

轻译的当前代码、资源与文档整体采用 GNU GPL 第 3 版（GPL-3.0-only）授权，许可正文见 [LICENSE](LICENSE)。分发 App 时提供对应版本的完整源码、资源和构建脚本。

## 当前翻译服务实现

| 服务 | 请求与解析方式 |
| --- | --- |
| 有道普通翻译 | 原生请求公开 jsonapi_s 接口，核对完整原文回显。长文按自然段及必要的句子边界组织，最多六路并发，保护代码、网址、版本与标记，再按原顺序显示。 |
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

触发翻译时，原文会发送给已开启的服务。两家内置服务免配置使用；服务网页、协议、网络和限流变化可能影响可用性。
