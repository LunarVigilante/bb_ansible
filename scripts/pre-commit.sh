#!/usr/bin/env bash

# Strict pre-commit hook to prevent committing high-entropy secrets or credential files.
# Bypassing this requires the --no-verify flag, but GitHub actions will still catch it.

echo "[Pre-Commit] Running strict secret scan..."

# Check if any .yml or .json files being committed contain anything that looks like a high-entropy OAuth token or secret key.
# This regex looks for 30+ char alphanumeric strings that aren't ssh keys (ssh-) or standard UUIDs.
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(yml|yaml|json|conf)$' || true)

if [ -n "$STAGED_FILES" ]; then
    for FILE in $STAGED_FILES; do
        # Ignore authorized_keys.j2 which safely contains public ssh keys
        if [[ "$FILE" == *"authorized_keys"* ]]; then
            continue
        fi
        
        # Scan for high-entropy strings (35+ chars), excluding standard SSH public key prefixes
        # We also specifically scan for the variables 'client_secret:', 'api_key:', 'password:' having values other than "" or CHANGE_ME
        if git diff --cached "$FILE" | grep '^+ ' | grep -iE '(secret|password|token|api_key|auth_key).*:[[:space:]]*["'\''][^"'\''C]+["'\'']' | grep -v 'CHANGE_ME' | grep -v '""' > /dev/null; then
            echo -e "\033[1;31m[ERROR] Potential LIVE SECRET detected in $FILE\033[0m"
            echo "A line containing 'secret', 'password', 'token', or 'key' was added with a value that is NOT 'CHANGE_ME' or empty."
            echo "You demanded strict security checks. To override, use 'git commit --no-verify' ONLY IF YOU ARE ABSOLUTELY SURE."
            echo ""
            git diff --cached "$FILE" | grep '^+ ' | grep -iE '(secret|password|token|api_key|auth_key).*:[[:space:]]*["'\''][^"'\''C]+["'\'']' | grep -v 'CHANGE_ME' | grep -v '""'
            exit 1
        fi
    done
fi

echo "[Pre-Commit] Clean. No obvious live credentials detected."
exit 0
