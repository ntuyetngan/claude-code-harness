#!/usr/bin/env bash
# Feeds representative Edit inputs to path-guard.sh and prints allow/BLOCK per case. Paths are test data; nothing is edited.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
ROOT="${1:?repo root}"; REPO="$(basename "$ROOT")"; LS="$HOME/.claude/loop-state"
J() { jq -cn --arg f "$ROOT/$1" --arg cwd "$ROOT" '{session_id:"pgtest",cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}'; }
t() { local out rc got mark; out=$(printf '%s' "$3" | ./path-guard.sh 2>&1); rc=$?; [ $rc -eq 2 ] && got=BLOCK || got=allow
  [ "$got" = "$1" ] && mark=ok || { mark=FAIL; FAILS=$((FAILS+1)); }; printf '%-4s %-5s %s\n' "$mark" "$got" "$2"; [ "$mark" = FAIL ] && printf '       %s\n' "${out:0:140}"; }
FAILS=0
rm -f "$LS/phase/$REPO" "$LS/allow/$REPO/nuxt" "$LS/allow/$REPO/tests" 2>/dev/null
t allow "app file" "$(J app/Http/Middleware/SetUser.php)"
t allow "en lang" "$(J resources/lang/en/auth.php)"
t allow "en frontend lang" "$(J resources/lang-frontend/zcs/en/zcs.php)"
t allow "docs" "$(J docs/checkout/receipts.md)"
t allow "tests when no phase" "$(J tests/Feature/FooTest.php)"
t allow "legacy (warn only)" "$(J legacy/foo.php)"
t allow "legacy_public (warn only)" "$(J legacy_public/admin/x.php)"
t BLOCK "nuxt" "$(J nuxt/pages/index.vue)"
t allow "ja lang (warn only)" "$(J resources/lang/ja/auth.php)"
t allow "ko frontend lang (warn only)" "$(J resources/lang-frontend/microsite/ko/checkout.php)"
t BLOCK "schema dump" "$(J database/schema/zaiko-schema.sql)"
t BLOCK ".env" "$(J .env)"
t BLOCK ".env.testing" "$(J .env.testing)"
t BLOCK "auth.json" "$(J auth.json)"
mkdir -p "$LS/allow/$REPO" && touch "$LS/allow/$REPO/nuxt"
t allow "nuxt with allow file" "$(J nuxt/pages/index.vue)"
rm -f "$LS/allow/$REPO/nuxt"
mkdir -p "$LS/phase" && echo fix > "$LS/phase/$REPO"
t BLOCK "tests during fix phase" "$(J tests/Feature/FooTest.php)"
t allow "app file during fix phase" "$(J app/Foo.php)"
touch "$LS/allow/$REPO/tests"
t allow "tests during fix phase with allow" "$(J tests/Feature/FooTest.php)"
rm -f "$LS/allow/$REPO/tests"
printf 'fix\ntests/Feature/FooTest.php\n' > "$LS/phase/$REPO"
t BLOCK "named regression test during fix phase" "$(J tests/Feature/FooTest.php)"
t allow "other test during fix phase" "$(J tests/Feature/BarTest.php)"
touch "$LS/allow/$REPO/tests"
t allow "named regression test with allow" "$(J tests/Feature/FooTest.php)"
rm -f "$LS/allow/$REPO/tests"
rm -f "$LS/phase/$REPO"
touch -d '13 hours ago' "$LS/allow/$REPO/nuxt"
t BLOCK "nuxt with expired allow file" "$(J nuxt/pages/index.vue)"
rm -f "$LS/allow/$REPO/nuxt"
echo "failures: $FAILS"; exit $FAILS
