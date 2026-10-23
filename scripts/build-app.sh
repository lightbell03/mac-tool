#!/usr/bin/env bash
# Release 빌드 후 WheelSpace.app 번들을 조립하고 로컬 고정 인증서로 서명한다.
# 사용법: scripts/build-app.sh [--install]   (--install: ~/Applications/WheelSpace.app 에 복사)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WheelSpace"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

# 로컬 서명용 자체 서명 인증서. 매번 같은 인증서로 서명해야 macOS가 재빌드한 앱을 같은 앱으로 보고
# 손쉬운 사용·입력 모니터링 권한을 유지한다 (ad-hoc 서명은 빌드마다 바뀌어 권한이 풀린다).
# 이 맥 안에서만 쓰는 키라 전용 키체인 암호를 스크립트에 둔다.
SIGN_NAME="WheelSpace Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/wheelspace-signing.keychain-db"
SIGN_KEYCHAIN_PASSWORD="wheelspace-local"

ensure_signing_identity() {
    if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
        echo "로컬 서명 인증서 생성: $SIGN_NAME"
        local tmp
        tmp="$(mktemp -d)"
        # macOS 기본 LibreSSL: Homebrew OpenSSL 3+의 PKCS#12는 security import가 못 읽을 수 있다
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$SIGN_NAME" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" \
            -addext "basicConstraints=critical,CA:false" 2>/dev/null
        /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -out "$tmp/identity.p12" -passout pass:wheelspace -name "$SIGN_NAME"
        security create-keychain -p "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
        security set-keychain-settings "$SIGN_KEYCHAIN"   # 자동 잠금 끄기
        security unlock-keychain -p "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
        security import "$tmp/identity.p12" -k "$SIGN_KEYCHAIN" -P wheelspace -T /usr/bin/codesign >/dev/null
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN" >/dev/null
        rm -rf "$tmp"
    fi
    security unlock-keychain -p "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
    # codesign은 검색 목록에 있는 키체인에서만 신뢰 설정 없는 인증서를 찾는다
    if ! security list-keychains -d user | grep -q "wheelspace-signing.keychain-db"; then
        local current
        current="$(security list-keychains -d user | tr -d '"' | xargs)"
        # shellcheck disable=SC2086
        security list-keychains -d user -s $current "$SIGN_KEYCHAIN"
    fi
}

cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ensure_signing_identity
codesign --force --sign "$SIGN_NAME" --identifier com.bell.WheelSpace "$APP"
echo "빌드 완료: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP" "$INSTALL_DIR/"
    echo "설치 완료: $INSTALL_DIR/$APP_NAME.app"
fi
