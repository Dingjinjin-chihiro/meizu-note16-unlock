#!/system/bin/sh
# =============================================================
# meizu-freeze.sh — 魅族 / Flyme 应用冻结工具（设备端版本）
#
# 用法（必须 root）：
#   su -c "sh /sdcard/freeze/meizu-freeze.sh freeze   /sdcard/freeze/list.txt"
#   su -c "sh /sdcard/freeze/meizu-freeze.sh unfreeze /sdcard/freeze/list.txt"
#   su -c "sh /sdcard/freeze/meizu-freeze.sh status   /sdcard/freeze/list.txt"
#   su -c "sh /sdcard/freeze/meizu-freeze.sh export   /sdcard/freeze/frozen.txt"
#
# 列表格式：每行一个包名，# 开头为注释，空行忽略
#
# 原理：pm disable-user / pm enable，与「小黑屋」冻结同一机制
#      只冻结不卸载，随时可解冻
# =============================================================

ACTION="${1:-status}"
LIST="${2:-}"

# ---- 保护名单：绝不冻结 ----
PROTECT="android com.android.systemui com.android.settings com.android.providers.settings \
com.android.shell com.android.phone com.android.phone.injection com.android.server.telecom \
com.android.providers.telephony com.android.providers.contacts com.android.providers.media \
com.android.providers.media.module com.android.permissioncontroller com.android.packageinstaller \
com.android.webview com.google.android.webview com.android.bluetooth com.android.nfc \
com.android.networkstack com.android.networkstack.tethering com.android.providers.downloads \
com.android.externalstorage com.android.documentsui com.android.intentresolver com.android.keychain \
com.android.certinstaller com.android.location.fused com.android.inputdevices com.android.se \
com.android.role.notes.enabled com.android.carrierconfig com.android.dialer com.android.mms \
com.android.mms.service com.android.incallui com.android.ons com.android.providers.blockednumber \
com.android.providers.userdictionary com.spreadtrum.ims com.spreadtrum.sgps \
com.android.unisoc.telephony.server com.unisoc.phone com.meizu.flyme.launcher \
com.sohu.inputmethod.sogou.meizu me.weishu.kernelsu web1n.stopapp"

is_protected() {
    case "$1" in
        android.*|com.android.internal.*|com.android.theme.*|*.overlay|com.android.wifi.*|com.unisoc.*) return 0 ;;
    esac
    for _pp in $PROTECT; do
        [ "$_pp" = "$1" ] && return 0
    done
    return 1
}

need_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "❌ 需要 root。请用: su -c \"sh $0 $*\""
        exit 1
    fi
}

read_list() {
    [ -f "$LIST" ] || { echo "❌ 列表文件不存在: $LIST"; exit 1; }
    sed -e 's/\r$//' -e 's/#.*//' "$LIST" | awk 'NF {print $1}'
}

case "$ACTION" in
    freeze)
        need_root
        [ -n "$LIST" ] || { echo "❌ 缺少列表文件参数"; exit 1; }
        INSTALLED="$(pm list packages | sed 's/^package://')"
        DISABLED="$(pm list packages -d | sed 's/^package://')"
        ok=0; prot=0; miss=0; already=0; fail=0
        for p in $(read_list); do
            if is_protected "$p"; then prot=$((prot+1)); continue; fi
            echo "$INSTALLED" | grep -qx "$p" || { miss=$((miss+1)); continue; }
            echo "$DISABLED" | grep -qx "$p" && { already=$((already+1)); continue; }
            if pm disable-user --user 0 "$p" 2>/dev/null | grep -q "new state: disabled"; then
                echo "  ✅ $p"; ok=$((ok+1))
            else
                echo "  ❌ $p"; fail=$((fail+1))
            fi
        done
        echo ""
        echo "冻结成功: $ok   已冻结: $already   保护跳过: $prot   未安装: $miss   失败: $fail"
        ;;
    unfreeze)
        need_root
        [ -n "$LIST" ] || { echo "❌ 缺少列表文件参数"; exit 1; }
        DISABLED="$(pm list packages -d | sed 's/^package://')"
        ok=0; skip=0
        for p in $(read_list); do
            echo "$DISABLED" | grep -qx "$p" || { skip=$((skip+1)); continue; }
            if pm enable "$p" 2>/dev/null | grep -q "new state: enabled"; then
                echo "  ✅ $p"; ok=$((ok+1))
            else
                echo "  ❌ $p"
            fi
        done
        echo ""
        echo "解冻成功: $ok   跳过: $skip"
        ;;
    status)
        [ -n "$LIST" ] || { echo "❌ 缺少列表文件参数"; exit 1; }
        INSTALLED="$(pm list packages | sed 's/^package://')"
        DISABLED="$(pm list packages -d | sed 's/^package://')"
        for p in $(read_list); do
            if ! echo "$INSTALLED" | grep -qx "$p"; then s="未安装"
            elif echo "$DISABLED" | grep -qx "$p"; then s="已冻结"
            else s="启用中"; fi
            printf "%-45s %s\n" "$p" "$s"
        done
        ;;
    export)
        need_root
        OUT="${LIST:-/sdcard/freeze/frozen.txt}"
        pm list packages -d | sed 's/^package://' | sort > "$OUT"
        echo "已导出 $(wc -l < "$OUT") 个已冻结应用到: $OUT"
        ;;
    *)
        echo "用法: sh $0 {freeze|unfreeze|status|export} <列表文件>"
        ;;
esac

