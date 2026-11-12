#!/bin/zsh
# 在登录钥匙串里创建一个本机自签名代码签名证书「openbean local signing」。
# 用它签名后，系统按「App 标识 + 证书」识别 openbean，重新打包也不用重新授权蓝牙/辅助功能。
# 只用于本机开发；对外发布请用 Apple Developer ID 证书并公证。
set -e
NAME="openbean local signing"
security find-identity -p codesigning | grep -q "\"$NAME\"" && { echo "已存在：$NAME"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
P=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -out "$T/id.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" -passout pass:$P 2>/dev/null
security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P $P -T /usr/bin/codesign
echo "已创建：$NAME"
