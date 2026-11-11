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

## 配置自动同步

在分发仓库的 Actions secrets 中设置 `SOURCE_RELEASES_TOKEN`。使用 `BMCShell` 组织下的细粒度令牌，仓库权限选择 `Contents: Read-only`，仓库范围选 `bmcshell-tool-ipmi`、`bmcshell-tool-redfish` 和 `bmcshell-tool-snmp`。分发仓库的 Release 和索引由该工作流自己的 `GITHUB_TOKEN` 写入。[创建细粒度令牌](https://github.com/settings/personal-access-tokens/new?name=BMCShell%20Release%20Reader&target_name=BMCShell&contents=read) · [设置 Actions secret](https://github.com/BMCShell/packages/settings/secrets/actions/new)

同步工作流每小时检查已发布的版本。添加令牌或需要立即同步时，可以在 Actions 中手动运行 **Sync public packages**。同版本的公开附件会复用，内容变化时请发布新版本。[同步工作流](https://github.com/BMCShell/packages/actions/workflows/sync-source.yml)

