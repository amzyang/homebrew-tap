#!/usr/bin/env bash
# 发布新版 kitty formula：取上游发布包、校验补丁仍可应用、同步 slang 与 Nerd Font 版本、改写 formula、本地构建、提交推送。
#
# 用法: scripts/bump-kitty.sh <上游版本> [选项]
#   --patch FILE   用该文件替换 formula 末尾内嵌的补丁（补丁与上游冲突后重新生成时用）
#   --no-build     跳过 brew reinstall --build-from-source 验证
#   --no-push      只提交不推送
#   --dry-run      只校验并打印将写入的 formula diff，不改文件
#
# 上游同版本再次发布时，-amz.N 自动递增。
set -euo pipefail

TAP_DIR=$(cd "$(dirname "$0")/.." && pwd)
FORMULA="$TAP_DIR/Formula/kitty.rb"
SLANG_RELEASES="https://github.com/shader-slang/slang/releases/download"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

version="" patch_file="" do_build=1 do_push=1 dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --patch) patch_file=$2; shift 2 ;;
    --no-build) do_build=0; shift ;;
    --no-push) do_push=0; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    -*) echo "未知选项: $1" >&2; usage ;;
    *) version=$1; shift ;;
  esac
done
[ -n "$version" ] || usage
version=${version#v}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. 上游发布包
tarball="kitty-$version.tar.xz"
url="https://github.com/kovidgoyal/kitty/releases/download/v$version/$tarball"
echo "==> 下载 $url"
curl -fsSL -o "$work/$tarball" "$url"
sha=$(shasum -a 256 "$work/$tarball" | cut -d' ' -f1)
mkdir "$work/src"
tar xJf "$work/$tarball" -C "$work/src" --strip-components=1

# 2. 补丁：默认取 formula 里 __END__ 之后的内容
if [ -n "$patch_file" ]; then
  cp "$patch_file" "$work/kitty.patch"
else
  sed -n '/^__END__$/,$p' "$FORMULA" | tail -n +2 > "$work/kitty.patch"
fi
sed -i 's/[[:space:]]*$//' "$work/kitty.patch"
echo "==> 校验补丁"
if ! (cd "$work/src" && patch -g 0 -f -p1 --dry-run -i "$work/kitty.patch" >"$work/patch.log" 2>&1); then
  cat "$work/patch.log" >&2
  cat >&2 <<'EOF'
补丁无法应用到该版本。先确认上游 padding_fill_strategy 是否已支持按轴设置（支持则删除本 formula 退回官方 cask）；
否则在上游源码树手工合入源码改动，./dev.sh build 后用编好的二进制重新生成选项代码：
  kitty/launcher/kitty +runpy "import sys,os; sys.path.insert(0,os.getcwd()); from gen.__main__ import main; main(['gen','config'])"
导出 8 个文件的 git diff，再以 --patch FILE 重跑本脚本。
EOF
  exit 1
fi

# 3. slang 版本跟随上游 bypy/sources.json
slang_ver=$(python3 -c "import json,sys; print(next(x['name'].split()[1] for x in json.load(open(sys.argv[1])) if x['name'].startswith('slang ')))" "$work/src/bypy/sources.json")
cur_slang=$(sed -n 's|.*/slang/releases/download/v\([^/]*\)/.*|\1|p' "$FORMULA" | head -1)
declare -A slang_sha
if [ "$slang_ver" != "$cur_slang" ]; then
  echo "==> slang $cur_slang -> $slang_ver"
  for arch in aarch64 x86_64; do
    curl -fsSL -o "$work/slang-$arch.tar.gz" "$SLANG_RELEASES/v$slang_ver/slang-$slang_ver-macos-$arch.tar.gz"
    slang_sha[$arch]=$(shasum -a 256 "$work/slang-$arch.tar.gz" | cut -d' ' -f1)
  done
fi

# 3b. Nerd Font 跟随 kitty 打包脚本：bypy/devenv.go 的 NERD_URL 指向 releases/latest，
#     发布时解析一次重定向把 latest 钉成具体 tag，与 kitty 官方包同步而 formula 仍可校验 sha256。
nerd_url=$(sed -n 's/.*NERD_URL *= *"\([^"]*\)".*/\1/p' "$work/src/bypy/devenv.go" | head -1)
nerd_pinned=$(curl -sI "$nerd_url" | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r' | head -1)
nerd_tag=$(echo "$nerd_pinned" | sed -n 's|.*/download/\([^/]*\)/.*|\1|p')
cur_nerd=$(sed -n 's|.*/nerd-fonts/releases/download/\([^/]*\)/.*|\1|p' "$FORMULA" | head -1)
nerd_sha=""
if [ -n "$nerd_tag" ] && [ "$nerd_tag" != "$cur_nerd" ]; then
  echo "==> Nerd Font $cur_nerd -> $nerd_tag"
  curl -fsSL -o "$work/nerd.tar.xz" "$nerd_pinned"
  nerd_sha=$(shasum -a 256 "$work/nerd.tar.xz" | cut -d' ' -f1)
fi

# 4. 版本号：上游同版本则递增 -amz.N
cur_version=$(sed -n 's/^  version "\(.*\)"/\1/p' "$FORMULA")
cur_upstream=${cur_version%-amz.*}
cur_n=${cur_version##*-amz.}
if [ "$cur_upstream" = "$version" ]; then n=$((cur_n + 1)); else n=1; fi
new_version="$version-amz.$n"

# 5. 改写 formula
python3 - "$FORMULA" "$work/kitty.rb" "$work/kitty.patch" "$url" "$sha" "$new_version" "$slang_ver" \
  "${slang_sha[aarch64]:-}" "${slang_sha[x86_64]:-}" "$nerd_pinned" "$nerd_sha" <<'EOF'
import re, sys
src, dst, patch, url, sha, version, slang_ver, sha_arm, sha_x86, nerd_url, nerd_sha = sys.argv[1:]
head = open(src).read().split('\n__END__\n')[0]
head = re.sub(r'^  url ".*"$', f'  url "{url}"', head, count=1, flags=re.M)
head = re.sub(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{sha}"', head, count=1, flags=re.M)
head = re.sub(r'^  version ".*"$', f'  version "{version}"', head, count=1, flags=re.M)
if sha_arm:
    for arch, digest in (('aarch64', sha_arm), ('x86_64', sha_x86)):
        head = re.sub(
            r'(url "https://github.com/shader-slang/slang/releases/download/)v[^/]+/slang-[^-]+-macos-' + arch + r'\.tar\.gz"\n(\s+)sha256 "[0-9a-f]{64}"',
            lambda m: f'{m.group(1)}v{slang_ver}/slang-{slang_ver}-macos-{arch}.tar.gz"\n{m.group(2)}sha256 "{digest}"',
            head, count=1)
if nerd_sha:
    head = re.sub(
        r'(url ")https://github\.com/ryanoasis/nerd-fonts/releases/download/[^"]+"\n(\s+)sha256 "[0-9a-f]{64}"',
        lambda m: f'{m.group(1)}{nerd_url}"\n{m.group(2)}sha256 "{nerd_sha}"',
        head, count=1)
open(dst, 'w').write(head + '\n__END__\n' + open(patch).read())
EOF

if [ "$dry_run" = 1 ]; then
  echo "==> dry-run，formula 变更如下（未写入）"
  diff -u "$FORMULA" "$work/kitty.rb" || true
  exit 0
fi
cp "$work/kitty.rb" "$FORMULA"
echo "==> formula 已更新为 $new_version"

# 6. 本地构建验证
if [ "$do_build" = 1 ]; then
  echo "==> brew reinstall --build-from-source amzyang/tap/kitty"
  brew reinstall --build-from-source --formula amzyang/tap/kitty
  /opt/homebrew/opt/kitty/bin/kitty +runpy \
    "from kitty.config import load_config; o = load_config(overrides=['padding_fill_strategy background neighboring_cell']); assert o.padding_fill_strategy == ('background', 'neighboring_cell'), o.padding_fill_strategy"
fi

# 7. 提交、推送
cd "$TAP_DIR"
git add Formula/kitty.rb
git commit -q -m "kitty $new_version"
echo "==> committed: $(git log --oneline -1)"
if [ "$do_push" = 1 ]; then
  git push -q origin HEAD
  echo "==> pushed"
fi
echo "机器上升级: brew upgrade kitty，然后退出并重开 kitty。"
