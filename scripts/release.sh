#!/usr/bin/env bash
# 버전을 올리고 유니버설 앱을 빌드해 zip으로 묶은 뒤 GitHub Release로 올린다.
# 사용법: scripts/release.sh <버전> [--draft]   예) scripts/release.sh 0.2.0
#   --draft: 공개하지 않고 초안 릴리스로 만든다 (확인 후 GitHub에서 공개)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WheelSpace"
REPO="lightbell03/mac-tool"
GH_HOST="github.com"
PLIST="$ROOT/Resources/Info.plist"
BUILD_DIR="$ROOT/build"

VERSION=""
DRAFT=false

die() {
    echo "오류: $*" >&2
    exit 1
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --draft) DRAFT=true ;;
            *) VERSION="$arg" ;;
        esac
    done
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "사용법: scripts/release.sh <버전 X.Y.Z> [--draft]"
}

check_preconditions() {
    cd "$ROOT"
    [[ -z "$(git status --porcelain)" ]] || die "커밋하지 않은 변경이 있습니다"
    [[ "$(git branch --show-current)" == "main" ]] || die "main 브랜치에서만 릴리스합니다"
    git fetch -q origin
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "origin/main과 커밋이 다릅니다 (pull 또는 push 먼저)"
    if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
        || [[ -n "$(git ls-remote --tags origin "refs/tags/v$VERSION")" ]]; then
        die "태그 v$VERSION이 이미 있습니다"
    fi
    gh auth status -h "$GH_HOST" >/dev/null 2>&1 || die "github.com 로그인이 필요합니다: gh auth login -h $GH_HOST"
}

bump_version() {
    local build
    build="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
    plutil -replace CFBundleVersion -string "$((build + 1))" "$PLIST"
    echo "버전: $VERSION (빌드 $((build + 1)))"
}

build_zip() {
    "$ROOT/scripts/build-app.sh" --universal
    local archs
    archs="$(lipo -archs "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME")"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "유니버설 바이너리가 아닙니다: $archs"
    ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$BUILD_DIR/$APP_NAME.app" "$ZIP"
    (cd "$BUILD_DIR" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
    echo "묶음 완료: $ZIP"
}

commit_and_tag() {
    git add "$PLIST"
    git commit -q -m "버전 $VERSION"
    git tag -a "v$VERSION" -m "$APP_NAME $VERSION"
    git push -q origin main "v$VERSION"
}

release_notes() {
    # HEAD는 방금 만든 버전 커밋이라 그 이전(HEAD^)까지만 모은다
    local prev range
    if prev="$(git describe --tags --abbrev=0 --match 'v*' HEAD^ 2>/dev/null)"; then
        range="$prev..HEAD^"
    else
        range="HEAD^"
    fi
    git log --format='- %s' "$range"
    cat <<'NOTES'

## 설치

1. `WheelSpace-*.zip`을 받아 풀고 `WheelSpace.app`을 `~/Applications`로 옮깁니다.
2. Apple 공증을 받지 않은 앱이라 처음 한 번은 막힙니다. 아래 중 하나로 풉니다.
   - 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"
   - 터미널: `xattr -dr com.apple.quarantine ~/Applications/WheelSpace.app`
3. 실행 후 입력 모니터링·손쉬운 사용 권한을 허용합니다.
NOTES
}

create_release() {
    local draft_flag=()
    [[ "$DRAFT" == true ]] && draft_flag=(--draft)
    GH_HOST="$GH_HOST" gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" \
        --repo "$REPO" --title "$APP_NAME $VERSION" --notes "$(release_notes)" \
        ${draft_flag[@]+"${draft_flag[@]}"}
}

parse_args "$@"
check_preconditions
bump_version
build_zip
commit_and_tag
create_release
