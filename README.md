# BMCShell 公开软件源

这里托管 BMCShell 通用插件的发布包和软件源索引。每个版本的 ZIP 和 SHA-256 清单都可以在 [Releases](https://github.com/BMCShell/packages/releases) 下载。

## 使用

```bash
bmc setting --set plugin.source.official https://raw.githubusercontent.com/BMCShell/packages/main/index.json
bmc plugin update
bmc plugin search ipmi
bmc plugin install bmcshell-tool-ipmi
```

索引列出 IPMI、Redfish 和 SNMP 通用插件。要固定版本，可以运行 `bmc plugin install bmcshell-tool-ipmi@1.0.1`。

## 发布流程

插件仓库推送与包清单版本相同的 `v<version>` tag 后，工作流在该仓库生成 ZIP 和校验清单。分发仓库从已发布的 Release 同步这两份附件，确认公开下载的 SHA-256 后更新 `index.json`。公开 Release tag 采用 `<package>-v<version>`。

