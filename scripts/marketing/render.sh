#!/bin/bash
# Renders the app screens used in the README images, then composes the final 1600×900 images.
# Each screen opens briefly in a corner of your display to be captured; don't click while it runs.
#   scripts/marketing/render.sh            → docs/images/{hero,focus,time,insights}.png
# Runs against a copy of the sources with a fake Keychain, in a temporary home folder, under its own
# defaults domain — the installed app's data and settings are never touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/marketing"
WORK="$(mktemp -d /tmp/moxie-marketing.XXXX)"
BIN="MoxieMarketing_$$"   # unique name = its own defaults domain
SHOTS="$WORK/shots"
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$BIN.plist"; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src" "$WORK/home" "$SHOTS"
find "$ROOT/Sources/MoxieTimer" -name '*.swift' ! -name MoxieTimerApp.swift ! -name Keychain.swift -exec cp {} "$WORK/src/" \;
cp "$HERE/Harness.swift" "$WORK/src/"
cat > "$WORK/src/KeychainStub.swift" <<'SWIFT'
enum Keychain {
    static func get(_ account: String) -> String? { account == "apiKey" ? "demo-key" : nil }
    static func set(_ value: String?, for account: String) {}
}
SWIFT

# Demo-only tweaks to the copy: let the harness set state, show the fox with its crown,
# and pre-fill the composer for the "compose" shot.
cd "$WORK/src"
sed -i '' 's/private(set) var tasks: \[MoxieTask\]/var tasks: [MoxieTask]/; s/private(set) var justAdded/var justAdded/' TaskInbox.swift
sed -i '' 's/private(set) var block: FocusBlock?/var block: FocusBlock?/' FocusStore.swift
sed -i '' 's/return unlockedSpecies.contains(chosen) ? chosen : .blob/return .fox/' PetStore.swift
sed -i '' 's/if let chosen = PetAccessory(rawValue: settings.petAccessory), chosen.unlockLevel <= level { return chosen }/return .crown/' PetStore.swift
sed -i '' 's/@State private var name = ""/@State private var name = ProcessInfo.processInfo.environment["DEMO_NAME"] ?? ""/' QuickStartComposer.swift
sed -i '' 's/@State private var due: DueChoice = .none/@State private var due: DueChoice = ProcessInfo.processInfo.environment["DEMO_NAME"] == nil ? .none : .today/' QuickStartComposer.swift
sed -i '' 's/@State private var client: Ref?$/@State private var client: Ref? = ProcessInfo.processInfo.environment["DEMO_NAME"] == nil ? nil : Ref(id: "c-Northwind Studio", name: "Northwind Studio")/' QuickStartComposer.swift
sed -i '' 's/@State private var project: Ref?$/@State private var project: Ref? = ProcessInfo.processInfo.environment["DEMO_NAME"] == nil ? nil : Ref(id: "p-Website 2.0", name: "Website 2.0")/' QuickStartComposer.swift
sed -i '' 's/@State private var added: String?/@State private var added: String? = ProcessInfo.processInfo.environment["DEMO_ADDED"]/' QuickStartComposer.swift
sed -i '' 's/@State private var weekOffset = 0/@State private var weekOffset = Int(ProcessInfo.processInfo.environment["DEMO_WEEK"] ?? "0") ?? 0/' RecentTab.swift
sed -i '' 's/@State private var selectedDay: Date?/@State private var selectedDay: Date? = ProcessInfo.processInfo.environment["DEMO_DAY"].flatMap { Calendar.current.date(byAdding: .day, value: Int($0) ?? 0, to: Calendar.current.dateInterval(of: .weekOfYear, for: Calendar.current.date(byAdding: .weekOfYear, value: -1, to: .now)!)!.start) }/' RecentTab.swift
sed -i '' 's/@State private var period: Period = .week/@State private var period: Period = Period(rawValue: ProcessInfo.processInfo.environment["DEMO_PERIOD"] ?? "") ?? .week/' InsightsTab.swift
sed -i '' 's/@State private var openClient: String?/@State private var openClient: String? = ProcessInfo.processInfo.environment["DEMO_OPEN_CLIENT"]/' InsightsTab.swift
sed -i '' 's/\.frame(height: 470)/.frame(height: Double(ProcessInfo.processInfo.environment["DEMO_SCROLL"] ?? "470") ?? 470)/' InsightsTab.swift

echo "Building harness…"
swiftc -parse-as-library -Onone -suppress-warnings -o "$WORK/$BIN" ./*.swift

defaults write "$BIN" userEmail "demo@example.com"
defaults write "$BIN" apiBaseURL "http://127.0.0.1:9/api/public"   # unreachable on purpose: no network calls land
defaults write "$BIN" petEnabled -bool true
defaults write "$BIN" holdForReview -bool true

shot() { # name screen [ENV=value…] — each shot gets a fresh home, so state from one doesn't leak into the next
  local name=$1 screen=$2; shift 2
  mkdir -p "$WORK/home-$name"
  for key in focusState timerState; do defaults delete "$BIN" "$key" >/dev/null 2>&1 || true; done   # timer/focus state
  env CFFIXED_USER_HOME="$WORK/home-$name" TMPDIR="$WORK/home-$name/" "$@" "$WORK/$BIN" "$screen" "$SHOTS/$name.png"
}
shot compose compose DEMO_NAME="Update email signatures"
shot newtask newtask DEMO_ADDED="Added to Up next"
shot active active
shot timer timer
shot recent recent DEMO_WEEK=-1
shot insights insights DEMO_PERIOD=Month DEMO_SCROLL=1200 DEMO_OPEN_CLIENT="Northwind Studio"

# SHOTS_ONLY=<dir> keeps the raw captures and skips composing (then: compose.sh <dir>).
if [ -n "${SHOTS_ONLY:-}" ]; then mkdir -p "$SHOTS_ONLY" && cp "$SHOTS"/*.png "$SHOTS_ONLY/"; exit 0; fi

"$HERE/compose.sh" "$SHOTS"
