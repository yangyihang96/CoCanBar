#!/bin/zsh
# 构建并打包「小电拼.app」（带桌面小组件扩展和快捷指令），用本机的 Apple Development 证书签名。
# - 用 Xcode 工程构建：小组件扩展和快捷指令的元数据（Metadata.appintents）只有 Xcode 的构建流程会生成。
#   日常开发、单元测试和离屏截图仍然用 SwiftPM（swift build / swift test）。
# - 签名身份固定，重新构建后钥匙串仍会信任这个 app，不会反复弹授权框。
# - app 和小组件共享数据用的 App Group 按证书的 Team ID 拼成 `<Team ID>.com.local.CoCanBar`，
#   macOS 上这种写法不需要描述文件。Team ID 只写进 build/ 里的权限文件，不输出。
# 可用环境变量 CODESIGN_IDENTITY 指定其他证书（SHA-1 或名称）。
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

XC_BUILD="$ROOT/build/xcode"
xcodebuild -project "$ROOT/CoCanBar.xcodeproj" -target CoCanBar -configuration Release \
  SYMROOT="$XC_BUILD" OBJROOT="$XC_BUILD/obj" -quiet build

APP="$ROOT/build/小电拼.app"
WIDGET="$APP/Contents/PlugIns/CoCanBarWidget.appex"
PRODUCT="$XC_BUILD/Release/CoCanBar.app"
rm -rf "$APP"
ditto "$PRODUCT" "$APP"
# Xcode 会把中间产物登记到 LaunchServices。同一个 bundle id 有两份时，快捷指令和小组件可能找到没签名的那份，
# 所以复制完就注销并删掉它（下次构建会重新生成）
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PRODUCT" 2>/dev/null || true
rm -rf "$PRODUCT"
# 图标由 scripts/make-app-icon.swift 生成：暖色那版给 Finder，冷色那版给冷色主题的面板头部
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Support/AppIconCool.icns" "$APP/Contents/Resources/AppIconCool.icns"
plutil -lint "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist" >/dev/null
for metadata in "$APP/Contents/Resources/Metadata.appintents" "$WIDGET/Contents/Resources/Metadata.appintents"; do
  [[ -f "$metadata/extract.actionsdata" ]] || { echo "缺少快捷指令元数据：$metadata" >&2; exit 1; }
done

# app 和扩展的版本号要一致，不一致时系统不加载扩展
for key in CFBundleShortVersionString CFBundleVersion; do
  app_value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")
  widget_value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$WIDGET/Contents/Info.plist")
  if [[ "$app_value" != "$widget_value" ]]; then
    echo "版本号不一致：$key app=$app_value 小组件=$widget_value（同时改 Support/Info.plist 和 Support/Widget-Info.plist）" >&2
    exit 1
  fi
done

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
ENTITLEMENTS="$XC_BUILD/entitlements"
mkdir -p "$ENTITLEMENTS"

# 写权限文件。$1 文件名，$2 是否沙盒（小组件扩展必须沙盒），$3 App Group（空则不写），
# $4 沙盒里能否主动联网（小组件在菜单栏 app 没运行时自己读局域网，不碰令牌）
write_entitlements() {
  local file="$ENTITLEMENTS/$1" sandbox="$2" group="$3" network="$4"
  {
    print '<?xml version="1.0" encoding="UTF-8"?>'
    print '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print '<plist version="1.0">'
    print '<dict>'
    if [[ "$sandbox" == yes ]]; then
      print '	<key>com.apple.security.app-sandbox</key>'
      print '	<true/>'
    fi
    if [[ "$network" == yes ]]; then
      print '	<key>com.apple.security.network.client</key>'
      print '	<true/>'
    fi
    if [[ -n "$group" ]]; then
      print '	<key>com.apple.security.application-groups</key>'
      print '	<array>'
      print "		<string>$group</string>"
      print '	</array>'
    fi
    print '</dict>'
    print '</plist>'
  } > "$file"
  plutil -lint "$file" >/dev/null
}

GROUP=""
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "没有找到 Apple Development 签名证书，改用临时签名：钥匙串每次重建后可能要重新授权，桌面小组件也读不到数据" >&2
  IDENTITY="-"
else
  # 先签一次扩展，从签名里读出证书的 Team ID
  codesign --force --timestamp=none --sign "$IDENTITY" "$WIDGET"
  TEAM_ID=$(codesign -dv "$WIDGET" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [[ "$TEAM_ID" =~ '^[A-Z0-9]{10}$' ]]; then
    GROUP="$TEAM_ID.com.local.CoCanBar"
  else
    echo "读不到证书的 Team ID，不启用 App Group：桌面小组件会读不到数据" >&2
  fi
fi

write_entitlements widget.entitlements yes "$GROUP" yes
write_entitlements app.entitlements no "$GROUP" no
# 先签里面的扩展，再签外面的 app（不用 --deep，免得扩展的权限被 app 的覆盖）
codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS/widget.entitlements" \
  --sign "$IDENTITY" "$WIDGET"
codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS/app.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"

if [[ -n "$GROUP" ]]; then
  echo "App Group：已按证书的 Team ID 启用"
fi
echo "已生成：$APP"
