#!/usr/bin/env bash
# One-time, already done on 2026-09-28: bring the dev box key into WSL. The private key existed only
# inside the PuTTY file jumpcloud_key.ppk on Windows. Export it once with puttygen (Conversions > Export OpenSSH key) to
# C:\Users\ngan.nguyen\.ssh\jumpcloud_key_openssh, then run this script: it copies the file to
# ~/.ssh/devbox_jumpcloud with mode 600 (files under /mnt/c cannot be used by ssh, their mode is
# too open) and checks the box answers.
#   devbox-key.sh [path-to-exported-key]
set -uo pipefail
SRC="${1:-/mnt/c/Users/ngan.nguyen/.ssh/jumpcloud_key_openssh}"
DST="$HOME/.ssh/devbox_jumpcloud"
[ -f "$SRC" ] || { echo "no exported key at $SRC. In puttygen: Load jumpcloud_key.ppk, Conversions > Export OpenSSH key, save as jumpcloud_key_openssh in the same folder, then rerun." >&2; exit 2; }
head -1 "$SRC" | grep -q 'PRIVATE KEY' || { echo "$SRC does not look like an OpenSSH private key (first line: $(head -1 "$SRC" | cut -c1-40))" >&2; exit 2; }
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
cp "$SRC" "$DST" && chmod 600 "$DST" && echo "key copied to $DST (mode 600)"
if ssh -o BatchMode=yes -o ConnectTimeout=15 -p 9999 -i "$DST" -o IdentitiesOnly=yes ngan.nguyen@43.206.230.172 'echo ok from $(hostname)' 2>/tmp/devbox-key.err; then echo "dev box answers over ssh on port 9999"; else echo "dev box did not answer: $(tail -1 /tmp/devbox-key.err)"; exit 1; fi
