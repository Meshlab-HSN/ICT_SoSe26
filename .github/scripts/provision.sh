#!/bin/bash
set -e

# Environment variables provided by GitHub Actions
ACTOR="${GITHUB_ACTOR}"
PR_NUMBER="${PR_NUMBER}"
KEYS_FILE="ssh_keys.yaml"

# Backend configuration files
ROSTER_FILE="/opt/key-provision/vm_roster.json"
VM_MASTER_KEY="/opt/key-provision/vm_master_key"

# IP + Port Base
IP_BASE="10.35.42.10"
PORT_BASE="51000"

VM_USERNAME="stud"

# Helper function to post a comment to the PR and exit
post_comment_and_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    gh pr comment "$PR_NUMBER" --body "$message"
    exit "$exit_code"
}

echo "Analyzing PR from @${ACTOR}..."

# 1. Get the baseline YAML from the main branch
# If the file doesn't exist on main yet, create an empty file
if ! git show origin/main:"$KEYS_FILE" > main_baseline.yaml 2>/dev/null; then
    touch main_baseline.yaml
fi

# 2. Native YAML parsing & Diffing
# Parse the YAML. If the file is only comments, yq outputs 'null' or an empty string.
yq '.' "$KEYS_FILE" > pr.json
yq '.' main_baseline.yaml > main.json

# If yq outputs a completely empty file (0 bytes), force it to be "null" so jq can read it
[ -s pr.json ] || echo "null" > pr.json
[ -s main.json ] || echo "null" > main.json

# Use jq array subtraction. The '// []' tells jq: "If you see 'null', treat it as an empty array []"
NEW_ENTRIES=$(jq -s '(.[0] // []) - (.[1] // [])' pr.json main.json)
ENTRY_COUNT=$(echo "$NEW_ENTRIES" | jq 'length')

if [[ "$ENTRY_COUNT" -eq 0 ]]; then
    post_comment_and_exit "❌ **Validation Failed:** No new entries detected compared to the main branch."
elif [[ "$ENTRY_COUNT" -gt 1 ]]; then
    post_comment_and_exit "❌ **Validation Failed:** You added multiple entries. Please submit only your own."
fi

# Extract values from the JSON object
# Extract values from the JSON object
ADDED_NAME=$(echo "$NEW_ENTRIES" | jq -r '.[0].name')
ADDED_EMAIL=$(echo "$NEW_ENTRIES" | jq -r '.[0].email')
ADDED_KEY=$(echo "$NEW_ENTRIES" | jq -r '.[0].ssh_key')

if [[ "$ADDED_NAME" == "null" || -z "$ADDED_NAME" || "$ADDED_EMAIL" == "null" || -z "$ADDED_EMAIL" || "$ADDED_KEY" == "null" || -z "$ADDED_KEY" ]]; then
    post_comment_and_exit "❌ **Validation Failed:** Missing \`name\`, \`email\`, or \`ssh_key\` in your entry."
fi

# 3. Cryptographic Key Validation
echo "$ADDED_KEY" > temp.pub
if ! ssh-keygen -l -f temp.pub > /dev/null 2>&1; then
    post_comment_and_exit "❌ **Validation Failed:** The SSH key provided is not a valid public key."
fi

# 4. Find the VM ID in the Roster and Calculate IP/Port
if [[ ! -f "$ROSTER_FILE" ]]; then
    post_comment_and_exit "⚠️ **Infrastructure Error:** Roster file is missing on the runner. Notify an instructor."
fi

STUDENT_ID=$(jq -r ".\"$ADDED_EMAIL\" // empty" "$ROSTER_FILE")
if [[ -z "$STUDENT_ID" ]]; then
    post_comment_and_exit "❌ **Validation Failed:** The email \`$ADDED_EMAIL\` is not assigned a VM ID for this exam."
fi

# Calculate Internal IP
IP_PREFIX="${IP_BASE%.*}"
IP_SUFFIX="${IP_BASE##*.}"
STUDENT_IP="${IP_PREFIX}.$((IP_SUFFIX + STUDENT_ID))"

# Calculate External Port
STUDENT_PORT=$((PORT_BASE + STUDENT_ID))

# 5. Provision via Direct SSH
echo "Enrolling key into internal IP $STUDENT_IP (External Port: $STUDENT_PORT)..."

SSH_OPTS="-i $VM_MASTER_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

if ! ssh $SSH_OPTS "$VM_USERNAME"@"$STUDENT_IP" "echo '$ADDED_KEY' >> ~/.ssh/authorized_keys"; then
    post_comment_and_exit "⚠️ **Infrastructure Error:** Could not connect to internal VM at \`$STUDENT_IP\`. Please notify an instructor."
fi

# 6. Success
post_comment_and_exit "✅ **Success!** Thanks $ADDED_NAME, your key has been validated and injected.<br><br>You can now connect to your VM via SSH using port \`$STUDENT_PORT\`" 0
