# BMCShell 公开软件源

这里托管 BMCShell 通用插件的发布包和软件源索引。每个版本的 ZIP 和 SHA-256 清单都可以在 [Releases](https://github.com/BMCShell/packages/releases) 下载。

## 使用

```bash
bmc setting --set plugin.source.official https://raw.githubusercontent.com/BMCShell/packages/main/index.json
bmc plugin update
bmc plugin search ipmi
bmc plugin install bmcshell-tool-ipmi
```

索引列出 IPMI、Redfish 和 SNMP 通用插件，以及简讯、关怀和毒妇主题。要固定版本，可以运行 `bmc plugin install bmcshell-tool-ipmi@1.0.1`。

## 发布流程

通用工具的源仓库推送与包清单版本相同的 `v<version>` 标签后，工作流生成 ZIP 和校验清单。分发仓库同步这两份附件。主题 ZIP 和校验清单直接发布到本仓库。分发仓库的 Release 标签统一采用 `<package>-v<version>`。同步工作流检查公开下载的 SHA-256 和包标识后更新 `index.json`。

## 自动同步

同步工作流匿名读取 `bmcshell-tool-ipmi`、`bmcshell-tool-redfish` 和 `bmcshell-tool-snmp` 的公开发行版。分发仓库的 Release 和索引由该工作流自己的 `GITHUB_TOKEN` 写入。

工作流每小时检查已发布的版本。需要立即同步时，可以在 Actions 中手动运行 **Sync public packages**。同版本的公开附件会复用，内容变化时请发布新版本。[同步工作流](https://github.com/BMCShell/packages/actions/workflows/sync-source.yml)

