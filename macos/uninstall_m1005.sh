#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "Usage: uninstall_m1005.sh UID HOME CURRENT_APP" >&2
    exit 64
fi

user_uid=$1
user_home=$2
current_app=$3

case "$user_uid" in
    ''|*[!0-9]*) echo "Invalid user id." >&2; exit 64 ;;
esac
case "$user_home" in
    /Users/*) ;;
    *) echo "Refusing unexpected home directory: $user_home" >&2; exit 64 ;;
esac

queue_name=HP_LaserJet_M1005
labels='com.m1005printer.service com.m1005printer.service.v2 com.m1005printer.service.v3 com.m1005printer.service.v4 com.m1005printer.service.v5 com.m1005printer.service.v6 com.m1005printer.service.v7'

for label in $labels; do
    /bin/launchctl bootout "gui/$user_uid/$label" >/dev/null 2>&1 || true
done

if /usr/bin/lpstat -p "$queue_name" >/dev/null 2>&1; then
    /usr/sbin/lpadmin -x "$queue_name"
fi

# Stop only an M1005 process if a stale copy is still holding the local port.
for process_id in $(/usr/sbin/lsof -t -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null || true); do
    process_command=$(/bin/ps -p "$process_id" -o command= 2>/dev/null || true)
    case "$process_command" in
        *m1005-printer-service*) /bin/kill -TERM "$process_id" 2>/dev/null || true ;;
    esac
done

/bin/sleep 1

remove_if_present() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        /bin/rm -rf -- "$1"
    fi
}

remove_app_if_expected() {
    app_path=$1
    case "$app_path" in
        /Applications/*.app|"$user_home"/Applications/*.app) ;;
        *) return 0 ;;
    esac
    [ -d "$app_path" ] || return 0
    bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw \
        "$app_path/Contents/Info.plist" 2>/dev/null || true)
    if [ "$bundle_id" = "com.m1005printer.setup" ]; then
        /bin/rm -rf -- "$app_path"
    fi
}

remove_if_present "$user_home/Library/Application Support/M1005Printer"
remove_if_present "$user_home/Library/Logs/M1005Printer"
remove_if_present "$user_home/Library/Application Support/m1005-printer-service.conf"
remove_if_present "$user_home/Library/Application Support/m1005-printer-service.state"
remove_if_present "$user_home/Library/Application Support/m1005-printer-service.d"
remove_if_present "$user_home/Library/Application Support/m1005-printer-app.d"
remove_if_present "$user_home/Library/Preferences/com.m1005printer.setup.plist"
remove_if_present "$user_home/Library/Caches/com.m1005printer.setup"
remove_if_present "$user_home/Library/Saved Application State/com.m1005printer.setup.savedState"
remove_if_present "$user_home/Library/HTTPStorages/com.m1005printer.setup"
remove_if_present "$user_home/Library/WebKit/com.m1005printer.setup"
remove_if_present "$user_home/Library/Preferences/com.apple.print.custompresets.forprinter.HP_LaserJet_M1005.plist"

for report in "$user_home"/Library/Logs/DiagnosticReports/m1005-printer-service-*.ips; do
    [ -e "$report" ] && /bin/rm -f -- "$report"
done
for report in "$user_home"/Library/Application\ Support/CrashReporter/m1005-printer-service_*.plist; do
    [ -e "$report" ] && /bin/rm -f -- "$report"
done

remove_app_if_expected "$current_app"
remove_app_if_expected "/Applications/M1005Printer.app"
remove_app_if_expected "/Applications/HP LaserJet M1005.app"
remove_app_if_expected "$user_home/Applications/M1005Printer.app"
remove_app_if_expected "$user_home/Applications/HP LaserJet M1005.app"

/usr/sbin/pkgutil --forget com.m1005printer.pkg >/dev/null 2>&1 || true

echo "M1005 apps, printer queue, services, package receipt, data, and logs were removed."
