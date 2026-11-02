#!/usr/bin/env bash
# 一键配置 Android release 签名:生成/复用 keystore,并写入 GitHub Actions Secrets。
#
# 签名材料只留在本机与 GitHub Secrets;脚本不把 keystore 或密码写入仓库。
# 依赖 keytool、base64 与已登录的 gh CLI。

set -euo pipefail

REPO="Ricardo-Kaslana/MicroScritt"
KEYSTORE_FILE="${HOME}/.microscritt-signing/release.jks"
ALIAS="release"
TMP_B64=""

usage() {
  cat <<'EOF'
用法: tool/setup_android_signing.sh [选项]

生成或复用 Android release keystore,并写入 GitHub Actions Secrets。

选项:
  -r, --repo OWNER/REPO   目标仓库,默认 Ricardo-Kaslana/MicroScritt
  -k, --keystore PATH     keystore 路径,默认 ~/.microscritt-signing/release.jks
  -a, --alias NAME        key alias,默认 release
  -h, --help              显示帮助

已有 keystore 时用 -k 指向它;脚本会提示输入密码。密码交互输入,不落盘。
EOF
}

die() {
  printf '错误:%s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TMP_B64" ]; then
    rm -f "$TMP_B64"
  fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--repo)
      [ $# -ge 2 ] || die "$1 缺少参数"
      REPO="$2"
      shift 2
      ;;
    -k|--keystore)
      [ $# -ge 2 ] || die "$1 缺少参数"
      KEYSTORE_FILE="$2"
      shift 2
      ;;
    -a|--alias)
      [ $# -ge 2 ] || die "$1 缺少参数"
      ALIAS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数:$1(用 --help 查看用法)"
      ;;
  esac
done

for cmd in keytool base64 gh; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令:$cmd"
done

gh auth status >/dev/null 2>&1 || die "gh 未登录,请先运行 gh auth login"
gh repo view "$REPO" >/dev/null 2>&1 || die "无法访问仓库:$REPO"

mkdir -p "$(dirname "$KEYSTORE_FILE")"

STORE_PASSWORD=""
KEY_PASSWORD=""

if [ -f "$KEYSTORE_FILE" ]; then
  printf '检测到已有 keystore:%s\n' "$KEYSTORE_FILE"
  read -r -p "key alias [$ALIAS]: " input_alias
  ALIAS="${input_alias:-$ALIAS}"
  read -r -s -p "keystore 密码: " STORE_PASSWORD
  printf '\n'
  [ -n "$STORE_PASSWORD" ] || die "密码不能为空"
  read -r -s -p "密钥密码(回车沿用 keystore 密码): " KEY_PASSWORD
  printf '\n'
  KEY_PASSWORD="${KEY_PASSWORD:-$STORE_PASSWORD}"
else
  printf '将在仓库外生成新的 release keystore:%s\n' "$KEYSTORE_FILE"
  printf '请务必备份 keystore 与密码;丢失后无法覆盖升级已安装应用。\n'
  read -r -p "继续? [y/N] " answer
  case "$answer" in
    y|Y) ;;
    *) exit 0 ;;
  esac
  read -r -s -p "设置 keystore 密码: " STORE_PASSWORD
  printf '\n'
  read -r -s -p "再次输入密码: " STORE_PASSWORD_CONFIRM
  printf '\n'
  [ -n "$STORE_PASSWORD" ] || die "密码不能为空"
  [ "$STORE_PASSWORD" = "$STORE_PASSWORD_CONFIRM" ] || die "两次密码不一致"
  KEY_PASSWORD="$STORE_PASSWORD"
  MICROSCRITT_STORE_PASS="$STORE_PASSWORD" \
  MICROSCRITT_KEY_PASS="$KEY_PASSWORD" \
    keytool -genkeypair -v \
      -keystore "$KEYSTORE_FILE" \
      -alias "$ALIAS" \
      -keyalg RSA -keysize 4096 -validity 10000 \
      -dname "CN=MicroScritt Release, O=MicroScritt, C=US" \
      -storepass:env MICROSCRITT_STORE_PASS \
      -keypass:env MICROSCRITT_KEY_PASS
  chmod 600 "$KEYSTORE_FILE"
fi

# 先用 keytool 验证密码与 alias,避免把错误材料写进 Secrets。
MICROSCRITT_STORE_PASS="$STORE_PASSWORD" \
  keytool -list -keystore "$KEYSTORE_FILE" -alias "$ALIAS" \
    -storepass:env MICROSCRITT_STORE_PASS >/dev/null 2>&1 \
  || die "无法用该密码打开 keystore,或 alias 不存在:$ALIAS"

TMP_B64="$(mktemp)"
base64 < "$KEYSTORE_FILE" | tr -d '\n' > "$TMP_B64"

printf '写入 %s 的 Actions Secrets...\n' "$REPO"
gh secret set ANDROID_KEYSTORE_BASE64 -R "$REPO" < "$TMP_B64"
printf '%s' "$STORE_PASSWORD" | gh secret set ANDROID_KEYSTORE_PASSWORD -R "$REPO"
printf '%s' "$KEY_PASSWORD" | gh secret set ANDROID_KEY_PASSWORD -R "$REPO"
printf '%s' "$ALIAS" | gh secret set ANDROID_KEY_ALIAS -R "$REPO"

printf '\n完成。\n'
printf '  keystore: %s\n' "$KEYSTORE_FILE"
printf '  alias:    %s\n' "$ALIAS"
printf '  密码未保存:请立即存入密码管理器并离线备份 keystore。\n'

if gh workflow view release.yml -R "$REPO" >/dev/null 2>&1; then
  if read -r -p "现在触发一次验证构建? [y/N] " run_now; then
    case "$run_now" in
      y|Y)
        gh workflow run release.yml -R "$REPO" --ref main
        printf '已触发。查看进度:gh run list -R %s --workflow release.yml\n' "$REPO"
        ;;
    esac
  fi
else
  printf '发布工作流尚未出现在 %s;推送 .github/workflows/release.yml 后再验证。\n' "$REPO"
fi
