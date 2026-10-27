# AGENTS

本项目规则见 `.cursor/rules/` 下 4 个 `.mdc` 文件，全部 `alwaysApply: true`。

| 文件 | 作用 |
|---|---|
| 00-identity.mdc | 身份 + 回执 |
| 01-dual-use.mdc | 请求定性 |
| 02-output.mdc | 输出规范 |
| 03-workflow.mdc | 先读后写 / 编辑后验证 |

完整行为规范：`docs/persona-full.md`

验证方式：发「在吗」，应只回 `海鸥在线，你要整点薯条吗？`
