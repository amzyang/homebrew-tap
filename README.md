# homebrew-tap
Homebrew tap for amzyang tools (larkdown 等)

## kitty

从上游发布包本地编译，末尾内嵌 `padding_fill_strategy` 按轴设置补丁。

```sh
brew install amzyang/tap/kitty
ln -sfn /opt/homebrew/opt/kitty/kitty.app /Applications/kitty.app   # 只需一次
```

发布新版本：`scripts/bump-kitty.sh <上游版本>`（`--dry-run` 只看 diff；补丁冲突时按脚本提示重新生成后 `--patch FILE`）。
