# star-coder-skill

用于在 Linux、Docker 和 HPC 环境中交互式部署与管理 [code-server](https://github.com/coder/code-server) 的 Codex Skill。

## 安装

```bash
git clone https://github.com/YoungxxStar/star-coder-skill.git ~/.codex/skills/star-coder-skill
```

## 使用

在 Codex 中输入：

```text
使用 $star-coder-skill 配置 code-server
```

Skill 会先探测运行环境并询问最多 8 个核心问题，再完成安装、配置、启动和验证。
