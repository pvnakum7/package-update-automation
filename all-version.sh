#!/bin/bash

BITBUCKET_USER="$BITBUCKET_USER"
BITBUCKET_PASSWORD="$BITBUCKET_PASSWORD"
GITHUB_USER="$GITHUB_USER"
GITHUB_TOKEN="$GITHUB_TOKEN"
GIT_USERNAME="Automation Version-Update"
GIT_EMAIL="pvnakum7@gmail.com"
NPM_TOKEN="$GITHUB_TOKEN"
BRANCH_NAME=""
FEATURE_BRANCH="security_version_fix"

REPO_LIST="${REPO_LIST}"   # Passed as Jenkins string parameter (space separated)
PR_TITLE="Security Vulnerability Fix - applied for Major, Minor and Patch updates"
PR_DESC="This PR contains auto-fixed vulnerabilities using jenkins Pipeline."

WORKDIR="$WORKSPACE/repos"
REPORTDIR="$WORKSPACE/Vulnerability-Reports"
ZIP_FILE="$WORKSPACE/Vulnerability-Reports-Nested-Folder-$(date +%d-%m-%Y).zip"

EXCEL_REPORT="$WORKSPACE/Repo-Version-Update-Report-Nested-Folder-$(date +%d-%m-%Y).csv"

# Cleanup
[ -d "$WORKDIR" ] && rm -rf "$WORKDIR"/*
[ -d "$REPORTDIR" ] && rm -rf "$REPORTDIR"/*
[ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ] && [ "$WORKSPACE" != "/" ] && rm -rf "$WORKSPACE"/*

# Recreate dirs
mkdir -p "$WORKDIR"
mkdir -p "$REPORTDIR"

# Create CSV header (after cleanup)
echo 'Repo,Failed_Updates_Require_Manual_Attention?,Has Version Update?,Total Count,Update Count,Skipped Count,Failed Count,Patch,Minor,Major' > "$EXCEL_REPORT"

cd "$WORKDIR"

####################################
# Detect target base branch
####################################
detect_branch() {
    local repo_url="$1"
    local auth_url="$repo_url"

    if [[ "$repo_url" =~ github.com ]] && [ -n "$GITHUB_TOKEN" ]; then
        auth_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@${repo_url#https://}"
    elif [[ "$repo_url" =~ bitbucket.org ]] && [ -n "$BITBUCKET_USER" ] && [ -n "$BITBUCKET_PASSWORD" ]; then
        auth_url="https://${BITBUCKET_USER}:${BITBUCKET_PASSWORD}@${repo_url#https://}"
    fi

    for branch in dev development develop main; do
        if git ls-remote --exit-code --heads "$auth_url" "$branch" >/dev/null 2>&1; then
            echo "$branch"
            return 0
        fi
    done

    return 1
}

# -----------------------------
# AZURE SMTP Configuration
# -----------------------------
MAIL_TO="${MAIL_TO}"

AZURE_SMTP_HOST="smtp.azurecomm.net"
AZURE_SMTP_PORT="587"
AZURE_SMTP_USER="$AZURE_SMTP_USER"
#AZURE_SMTP_PASSWORD="$AZURE_SMTP_PASSWORD"
AZURE_SMTP_PASSWORD="$(printf '%s' "$AZURE_SMTP_PASSWORD" | tr -d '\r\n')"
#AZURE_SMTP_PASSWORD="$(echo -n "$VULNERABILITY_AZURE_SMTP_PASSWORD" | tr -d '\r\n')"
AZURE_MAIL_FROM="$AZURE_MAIL_FROM"


# -----------------------------
# Email function (multiple attachments)
# -----------------------------
send_email_azure_smtp() {
  local to_list="$1"
  local cc_list="$2"
  local subject="$3"
  local body="$4"
  shift 4
  local attachments=("$@")

  local smtp_host="${AZURE_SMTP_HOST:-smtp.azurecomm.net}"
  local smtp_port="${AZURE_SMTP_PORT:-587}"
  local boundary="====AZURE_SMTP_BOUNDARY_$(date +%s)===="

  local tmp_mail
  tmp_mail=$(mktemp)

  # Convert comma-separated lists into arrays
  IFS=',' read -ra TO_ARRAY <<< "$to_list"
  IFS=',' read -ra CC_ARRAY <<< "$cc_list"

  # -----------------------------
  # Build mail content
  # -----------------------------
  {
    echo "From: ${AZURE_MAIL_FROM}"
    echo "To: ${to_list}"

    if [ -n "$cc_list" ]; then
      echo "Cc: ${cc_list}"
    fi

    echo "Subject: ${subject}"
    echo "MIME-Version: 1.0"

    if [ "${#attachments[@]}" -gt 0 ]; then
      echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
      echo
      echo "--${boundary}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 7bit"
      echo
      printf "%b\n" "${body}"
    else
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 7bit"
      echo
      printf "%b\n" "${body}"
    fi

    # Attachments
    for file in "${attachments[@]}"; do
      [ -f "$file" ] || continue

      local filename
      local mime_type

      filename=$(basename "$file")
      mime_type=$(file --mime-type -b "$file" 2>/dev/null || echo "application/octet-stream")

      echo
      echo "--${boundary}"
      echo "Content-Type: ${mime_type}; name=\"${filename}\""
      echo "Content-Transfer-Encoding: base64"
      echo "Content-Disposition: attachment; filename=\"${filename}\""
      echo
      base64 "$file" | fold -w 76
    done

    [ "${#attachments[@]}" -gt 0 ] && echo "--${boundary}--"

  } > "$tmp_mail"

  echo "===== SMTP DEBUG ====="
  echo "SMTP Host: $smtp_host"
  echo "SMTP Port: $smtp_port"
  echo "From: $AZURE_MAIL_FROM"
  echo "To: $to_list"
  echo "Cc: $cc_list"
  echo "Subject: $subject"
  echo "Attachments: ${#attachments[@]}"
  echo "======================"

  # -----------------------------
  # Build recipient arguments
  # -----------------------------
  RECIPIENT_ARGS=()

  for email in "${TO_ARRAY[@]}"; do
    email=$(echo "$email" | xargs)
    [ -n "$email" ] && RECIPIENT_ARGS+=(--mail-rcpt "$email")
  done

  for email in "${CC_ARRAY[@]}"; do
    email=$(echo "$email" | xargs)
    [ -n "$email" ] && RECIPIENT_ARGS+=(--mail-rcpt "$email")
  done

  echo "SMTP User: [$AZURE_SMTP_USER]"
  echo "Password Length: ${#AZURE_SMTP_PASSWORD}"
  # -----------------------------
  # Send Email
  # -----------------------------
  curl  --verbose --show-error --fail \
    --url "smtp://${smtp_host}:${smtp_port}" \
    --ssl-reqd \
    --mail-from "${AZURE_MAIL_FROM}" \
    "${RECIPIENT_ARGS[@]}" \
    --upload-file "$tmp_mail" \
    --user "${AZURE_SMTP_USER}:${AZURE_SMTP_PASSWORD}"

  local status=$?

  rm -f "$tmp_mail"

  return $status
}


# ---------------- Java FUNCTIONS ----------------

# Only stable versions (no snapshots or alphas)
# is_stable_lts() {
#     local ver="$1"
#     [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] &&
#     ! [[ "$ver" =~ (alpha|beta|rc|RC|M|SNAPSHOT|a|b|c|ea|EA|pr|PR|preview|post) ]]
# }
# UPDATED: Stable version filter (reject pre-release / unstable tags)
is_stable_lts() {
    local ver
    ver="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

    #### Reject unstable/pre-release versions & Covers: alpha, beta, rc, snapshot, preview, ea, cr, milestone(m1,m2...), dev/post
    if [[ "$ver" =~ (alpha|beta|rc|snapshot|preview|ea|cr|m[0-9]+|\.dev|\.post) ]]; then
        return 1
    fi
    return 0
}

# Check if v2 is a minor or patch upgrade of v1 (same major)
is_minor_patch_upgrade() {
    local v1="$1" v2="$2"
    IFS='.' read -r v1_major v1_minor v1_patch <<< "$v1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$v2"

    v1_minor=${v1_minor:-0}; v1_patch=${v1_patch:-0}
    v2_minor=${v2_minor:-0}; v2_patch=${v2_patch:-0}

    [[ "$v2_major" -eq "$v1_major" ]] &&
    { [[ "$v2_minor" -gt "$v1_minor" ]] || 
      ([[ "$v2_minor" -eq "$v1_minor" ]] && [[ "$v2_patch" -gt "$v1_patch" ]]); }
}

safe_xml_update() {

    local xpath="$1"
    local new_value="$2"
    local artifact="$3"
    local current="$4"

    if xmlstarlet ed -L -N pom="$NS" -u "$xpath" -v "$new_value" "$POM"; then
        if ! xmlstarlet val "$POM" >/dev/null 2>&1; then
            echo "Error: Invalid XML after update for $artifact" >> "$REPORT"
            cp "$BACKUP" "$POM"

            print_table_row "$artifact" "$current" "$new_value" "FAILED" >> "$REPORT"
            ((FAILED_COUNT++))
            return 1
        fi
        return 0
    else
        echo "Error: xmlstarlet failed for $artifact" >> "$REPORT"
        print_table_row "$artifact" "$current" "$new_value" "FAILED" >> "$REPORT"
        ((FAILED_COUNT++))
        return 1
    fi
}
# Get latest stable version (across all majors — patch, minor, and major upgrades)
get_latest_version() {

    local groupid="$1"
    local artifact="$2"

    local group_path
    group_path=$(echo "$groupid" | tr . /)

    local urls=(
        "https://repo1.maven.org/maven2/$group_path/$artifact/maven-metadata.xml"
        "https://repository.mulesoft.org/releases/$group_path/$artifact/maven-metadata.xml"
        "https://maven.anypoint.mulesoft.com/api/v2/maven/$group_path/$artifact/maven-metadata.xml"
    )

    local tmpfile
    tmpfile=$(mktemp)

    for url in "${urls[@]}"; do
        if curl -s --fail "$url" -o "$tmpfile"; then

            LATEST=$(grep "<version>" "$tmpfile" | \
            sed 's/.*<version>\(.*\)<\/version>.*/\1/' | \
            while read -r v; do
                if is_stable_lts "$v"; then
                    echo "$v"
                fi
            done | \
            sort -V | \
            tail -n1)

            if [[ -n "$LATEST" ]]; then
                echo "$LATEST"
                rm -f "$tmpfile"
                return 0
            fi
        fi
    done

    rm -f "$tmpfile"
    return 1
}
# ===== Version Classification Function =====
classify_version_update() {
    local current=$1
    local latest=$2

    IFS='.' read -r c_major c_minor c_patch <<< "$current"
    IFS='.' read -r l_major l_minor l_patch <<< "$latest"

    if [[ "$l_major" -gt "$c_major" ]]; then
        echo "major"
    elif [[ "$l_major" -eq "$c_major" && "$l_minor" -gt "$c_minor" ]]; then
        echo "minor"
    elif [[ "$l_major" -eq "$c_major" && "$l_minor" -eq "$c_minor" && "$l_patch" -gt "$c_patch" ]]; then
        echo "patch"
    else
        echo "same"
    fi
}

print_table_header() {
    printf "%-45s | %-15s | %-15s | %-10s\n" "ARTIFACT" "CURRENT" "LATEST" "STATUS"
    printf "%-45s-+-%-15s-+-%-15s-+-%-10s\n" \
        "$(printf '%.0s-' {1..45})" \
        "$(printf '%.0s-' {1..15})" \
        "$(printf '%.0s-' {1..15})" \
        "$(printf '%.0s-' {1..10})"
}

print_table_row() {
    printf "%-45s | %-15s | %-15s | %-10s\n" "$1" "$2" "$3" "$4"
}

####################################
# Nested application folder support
####################################

# Returns 0 if the given directory (relative to repo root) contains a
# recognizable technology-stack file.
has_tech_stack_files() {
    local d="$1"
    [ -f "$d/angular.json" ] && return 0
    [ -f "$d/package.json" ] && return 0
    [ -f "$d/pom.xml" ] && return 0
    [ -f "$d/build.gradle" ] && return 0
    [ -f "$d/build.gradle.kts" ] && return 0
    [ -f "$d/requirements.txt" ] && return 0
    [ -f "$d/pyproject.toml" ] && return 0
    [ -f "$d/composer.json" ] && return 0
    return 1
}

# Discovers application folders to process, run from the repo root.
# - If the root itself has a supported tech stack, only "." is returned
#   (existing behavior, unchanged).
# - Otherwise, every folder up to 2 levels deep from the root that has a
#   supported tech stack is returned (one entry per application).
discover_app_dirs() {
    if has_tech_stack_files "."; then
        echo "."
        return 0
    fi

    find . -mindepth 1 -maxdepth 2 -type d \
        -not -path "*/.git*" -not -path "*/node_modules*" \
        2>/dev/null | sort | while read -r d; do
            if has_tech_stack_files "$d"; then
                echo "${d#./}"
            fi
        done
}

####################################
# Unified push/PR helper (single PR per repo, combining every detected
# application folder's changes)
####################################
push_changes() {
    local reponame="$1"
    shift
    local files=("$@")

    REMOTE_URL=$(git config --get remote.origin.url)
    echo "Remote URL detected: $REMOTE_URL"

    if [[ "$REMOTE_URL" == *"github.com"* ]]; then
        REPO_TYPE="github"
    elif [[ "$REMOTE_URL" == *"bitbucket.org"* ]]; then
        REPO_TYPE="bitbucket"
    else
        echo "ERROR: Unknown repository type → cannot push."
        return
    fi

    echo "Detected Repo Type (from remote URL): $REPO_TYPE"

    echo "Perform Git push"
    git config user.email "$GIT_EMAIL"
    git config user.name "$GIT_USERNAME"

    # remove old branches
    git branch -D "$FEATURE_BRANCH" 2>/dev/null || true
    git push origin --delete "$FEATURE_BRANCH" 2>/dev/null || true

    # create new branch
    git checkout -b "$FEATURE_BRANCH"

    if [ "${#files[@]}" -gt 0 ]; then
        git add -- "${files[@]}"
    else
        git add -A
    fi
    export HUSKY=0
    git commit -m "Security Fix: automated patch update" || echo "No changes to commit"
    git push -u origin "$FEATURE_BRANCH"
    sleep 2

    echo "Create PR based on repo type"

    if [[ "$REPO_TYPE" == "github" ]]; then

        echo "Creating GitHub PR..."
        OWNER=$(echo "$REMOTE_URL" \
            | sed -E 's#(.*/|.*:)([^/]+)/([^/]+)(\.git)?#\2#')
        echo "Extracted Owner dynamically: $OWNER"
        echo "Creating Pull Request on GitHub Repo: $OWNER/$reponame"

        RESPONSE=$(curl -s -X POST \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -d "{\"title\": \"$PR_TITLE\",\"body\": \"$PR_DESC\",\"head\": \"$FEATURE_BRANCH\",\"base\": \"$BRANCH_NAME\"}" \
            "https://api.github.com/repos/$OWNER/$reponame/pulls")

        sleep 2
        PR_ID=$(echo "$RESPONSE" | jq -r '.number // empty')
        echo "GitHub PR Number: $PR_ID"
        ((TOTAL_REPOS_PR++))

    elif [[ "$REPO_TYPE" == "bitbucket" ]]; then

        echo "Creating Bitbucket PR..."
        WORKSPACE=$(echo "$REMOTE_URL" \
            | sed -E 's#.*bitbucket.org/([^/]+)/.*#\1#')
        echo "Extracted Workspace dynamically: $WORKSPACE"

        RESPONSE=$(curl -s -u "$BITBUCKET_USER:$BITBUCKET_PASSWORD" \
            -X POST \
            -H "Content-Type: application/json" \
            -d '{
                "title": "'"$PR_TITLE"'",
                "description": "'"$PR_DESC"'",
                "source": { "branch": { "name": "'"$FEATURE_BRANCH"'" } },
                "destination": { "branch": { "name": "'"$BRANCH_NAME"'" } }
            }' \
            "https://api.bitbucket.org/2.0/repositories/$WORKSPACE/$reponame/pullrequests")

        PR_ID=$(echo "$RESPONSE" | jq -r '.id')
        echo "PR Response ID: $PR_ID"
        ((TOTAL_REPOS_PR++))
    fi
}

# ---------------- MAIN SCRIPT ----------------

TOTAL_REPOS_PR=0
TOTAL_REPOS_PACKAGE_COUNT=0
TOTAL_REPOS_UPDATED_COUNT=0
TOTAL_REPOS_SKIPPED_COUNT=0
TOTAL_REPOS_FAILED_COUNT=0

TOTAL_REPOS_PATCH_COUNT=0
TOTAL_REPOS_MINOR_COUNT=0
TOTAL_REPOS_MAJOR_COUNT=0

TOTAL_COUNT=0

PATCH_COUNT=0
MINOR_COUNT=0
MAJOR_COUNT=0

UPDATE_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0


for repo in $REPO_LIST; do
    echo "--------------------------------------"
    echo " Processing repo: $repo"
    echo "--------------------------------------"

    ####################################
    # Normalize repo URL
    ####################################
    if [[ "$repo" != http* ]]; then
        repo="https://$repo"
    fi
        ####################################
    # Detect base branch
    ####################################
    BRANCH_NAME=$(detect_branch "$repo")

    if [ -z "$BRANCH_NAME" ]; then
        echo "No supported branch found (dev/development/develop/main)"
        echo "Skipping repository..."
        continue
    fi

    echo "Selected Base Branch: $BRANCH_NAME"

    ####################################
    # Detect SCM provider
    ####################################
    if [[ "$repo" =~ github.com ]]; then
        PROVIDER="github"
        # BRANCH_NAME="main"
    elif [[ "$repo" =~ bitbucket.org ]]; then
        PROVIDER="bitbucket"
        # BRANCH_NAME="master"
    else
        echo "Unsupported SCM provider: $repo"
        continue
    fi

    ####################################
    # Extract repo name
    ####################################
    reponame=$(basename "$repo" .git)
    echo "Repo name : $reponame"
    echo "Provider  : $PROVIDER"

    ####################################
    # Clone or update repository
    ####################################
    if [ -d "$reponame/.git" ]; then
        cd "$reponame"
        echo "Repo already exists. Updating code..."
        # git checkout "$BRANCH_NAME" || git checkout -b "$BRANCH_NAME"
        # git pull origin "$BRANCH_NAME"
        git fetch origin

        if git show-ref --verify --quiet refs/heads/$BRANCH_NAME; then
            git checkout "$BRANCH_NAME"
        else
            git checkout -b "$BRANCH_NAME" origin/"$BRANCH_NAME"
        fi

        git pull origin "$BRANCH_NAME"
    else
        echo "Cloning repository..."
        pwd
        if [ "$PROVIDER" = "github" ]; then
            if [ -n "$GITHUB_TOKEN" ]; then
                git clone -b "$BRANCH_NAME" \
                  "https://${GITHUB_USER}:$GITHUB_TOKEN@${repo#https://}" \
                  "$reponame"
            else
                git clone -b "$BRANCH_NAME" "$repo" "$reponame"
            fi
        else
            if [ -n "$BITBUCKET_USER" ] && [ -n "$BITBUCKET_PASSWORD" ]; then
                git clone -b "$BRANCH_NAME" \
                  "https://$BITBUCKET_USER:$BITBUCKET_PASSWORD@${repo#https://}" \
                  "$reponame"
            else
                git clone -b "$BRANCH_NAME" "$repo" "$reponame"
            fi
        fi
        pwd
        cd "$reponame"
    fi

    #### -------Step 1: Detect application folders to process ----------
    REPO_BASE_DIR="$(pwd)"
    REPORT="$REPORTDIR/$reponame-upgrade-report.txt"
    : > "$REPORT"
    {
        echo "=============================================="
        echo "Major + Minor + Patch update process starts for $reponame"
        echo "=============================================="
        echo "Date: $(date)"
        echo ""
    } >> "$REPORT"

    mapfile -t APP_DIRS < <(discover_app_dirs)

    if [ "${#APP_DIRS[@]}" -eq 0 ]; then
        echo "Error: Could not detect application technology in root or nested folders."
        cd "$WORKDIR"
        continue
    fi

    echo "Detected application folder(s): ${APP_DIRS[*]}"

    # Per-repo aggregates (combined across every detected application folder)
    REPO_TOTAL_COUNT=0
    REPO_UPDATE_COUNT=0
    REPO_SKIPPED_COUNT=0
    REPO_FAILED_COUNT=0
    REPO_PATCH_COUNT=0
    REPO_MINOR_COUNT=0
    REPO_MAJOR_COUNT=0
    CHANGED_FILES=()

    for APPDIR in "${APP_DIRS[@]}"; do
    cd "$REPO_BASE_DIR" || continue
    if [ "$APPDIR" != "." ]; then
        cd "$APPDIR" || continue
    fi

    if [ "$APPDIR" = "." ]; then
        FOLDER_LABEL="Root Directory"
    else
        FOLDER_LABEL="Folder: $APPDIR"
    fi

    {
        echo ""
        echo "===================================================="
        echo "$FOLDER_LABEL"
        echo ""
    } >> "$REPORT"

    echo "Detecting App Technology tech Stack..."
    TECH_STACK="Unknown"

    # --- Angular (must be checked before generic NodeJS) ---
    if [ -f "package.json" ]; then
        if [ -f "angular.json" ] || grep -q '"@angular/core"' package.json 2>/dev/null; then
            echo "Angular"
            TECH_STACK="Angular"
        elif grep -qE '"express"|"@nestjs/core"|"fastify"|"koa"' package.json; then
            echo "Node.js (Express/NestJS)"
            TECH_STACK="NodeJS"
        elif grep -qE '"react"|"react-dom"' package.json; then
            echo "Node.js (React)"
            TECH_STACK="NodeJS"
        else
            echo "Node.js (Generic)"
            TECH_STACK="NodeJS"
        fi
    fi

    # --- Python ---
    if [ "$TECH_STACK" = "Unknown" ]; then
        if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || find . -name "*.py" | grep -q .; then
            TECH_STACK=$(grep -qi "flask" requirements.txt 2>/dev/null || grep -qi "flask" pyproject.toml 2>/dev/null || grep -Ri "from flask" . --include="*.py" > /dev/null && echo "Python (Flask)" || \
                        grep -qi "django" requirements.txt 2>/dev/null || grep -qi "django" pyproject.toml 2>/dev/null || grep -Ri "import django" . --include="*.py" > /dev/null && echo "Python (Django)" || \
                        grep -qi "fastapi" requirements.txt 2>/dev/null || grep -qi "fastapi" pyproject.toml 2>/dev/null || grep -Ri "from fastapi" . --include="*.py" > /dev/null && echo "Python (FastAPI)" || \
                        echo "Python (Generic)")
            TECH_STACK="Python"
        fi
    fi

    # --- Java ---
    if [ "$TECH_STACK" = "Unknown" ]; then
        POM_FILE=$(find . -name "pom.xml" -print -quit)
        GRADLE_FILE=$(find . -name "build.gradle" -print -quit)
        GRADLE_KTS_FILE=$(find . -name "build.gradle.kts" -print -quit)
        ANT_FILE=$(find . -name "build.xml" -print -quit)

        if [ -n "$POM_FILE" ]; then
            echo "Maven"
            TECH_STACK="Maven"
        elif [ -n "$GRADLE_FILE" ] || [ -n "$GRADLE_KTS_FILE" ]; then
            echo "Gradle"
            TECH_STACK="Gradle"
        elif [ -n "$ANT_FILE" ]; then
            echo "Java (Ant)"
            TECH_STACK="Java"
        elif find . -name "*.java" | grep -q .; then
            echo "Java (Generic)"
            TECH_STACK="Java"
        fi
    fi

    # --- PHP / Laravel ---
    if [ "$TECH_STACK" = "Unknown" ]; then
        if [ -f "composer.json" ]; then
            if grep -q '"laravel/framework"' composer.json 2>/dev/null; then
                echo "PHP (Laravel)"
            else
                echo "PHP (Generic)"
            fi
            TECH_STACK="PHP"
        fi
    fi
        
    if [ "$TECH_STACK" = "Unknown" ]; then
        echo "Error: Could not detect application technology for folder: $APPDIR"
        continue
    else
        echo "Application Detected: $TECH_STACK ($FOLDER_LABEL)"
    fi

    HAS_UPDATE="NO"
    ####################################
    echo "======================== $reponame ======================================"
    echo "============ Major + Minor + Patch update process start ========"
    echo "======================================================================================"


    if [ "$TECH_STACK" = "NodeJS" ]; then   
        if [ ! -f package.json ]; then
            echo "Error: NodeJS detected but no package.json found in folder: $APPDIR"
            continue
        fi

        printf "%-30s | %-12s | %-12s | %-20s\n" \
        "PACKAGE" "CURRENT" "LATEST" "STATUS" >> "$REPORT"
        printf "%-30s-+-%-12s-+-%-12s-+-%-20s\n" \
        "------------------------------" "------------" "------------" "--------------------" >> "$REPORT"

        # NAME_SKIP_PATTERN  – skip specific known-problematic packages by name
        # VER_SKIP_PATTERN   – filter pre-release tags from available version lists
        NAME_SKIP_PATTERN="react-quill|some-legacy-package"
        VER_SKIP_PATTERN="alpha|beta|rc|preview|canary|snapshot|nightly"

        TOTAL_COUNT=0
        UPDATE_COUNT=0
        SKIPPED_COUNT=0
        FAILED_COUNT=0

        PATCH_COUNT=0
        MINOR_COUNT=0
        MAJOR_COUNT=0

        ENGINE_UPDATED=0

        # Backup once per run
        cp package.json package.json.bak
        [ -f package-lock.json ] && cp package-lock.json package-lock.json.bak        # Read all dependencies (including devDependencies)
        # ✅ Read dependencies + type
        mapfile -t DEPS < <(
        jq -r '
        (.dependencies // {} | to_entries[] | "\(.key)\t\(.value)\tdep"),
        (.devDependencies // {} | to_entries[] | "\(.key)\t\(.value)\tdev")
        ' package.json
        )
        export NPM_TOKEN="$GITHUB_TOKEN"
        echo "NPM_TOKEN length: ${#NPM_TOKEN}"
        echo "GITHUB_TOKEN length: ${#GITHUB_TOKEN}"

        for entry in "${DEPS[@]}"; do
            IFS=$'\t' read -r NAME RANGE DEP_TYPE <<< "$entry"

            TOTAL_COUNT=$((TOTAL_COUNT+1))

            # Skip unwanted packages
            NAME_LC=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
            if [[ "$NAME_LC" =~ $NAME_SKIP_PATTERN ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$RANGE" "-" "SKIPPED (NAMED)" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            # Skip URL, git, file, and tarball-based entries — cannot be semver-updated
            if [[ "$RANGE" =~ ^(https?|git\+https?|git\+ssh|git|file|workspace): ]] || \
               [[ "$RANGE" =~ \.(tgz|tar\.gz)$ ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$RANGE" "-" "SKIPPED (URL/FILE)" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            CURRENT=$(echo "$RANGE" | sed 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
            [[ -z "$CURRENT" ]] && { ((SKIPPED_COUNT++)); continue; }

            # ✅ Get available versions
            ALL_VERSIONS=$(npm view "$NAME" versions --json 2>/dev/null | jq -r 'if type == "array" then .[] else . end' || true)
            
            if [[ -z "$ALL_VERSIONS" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "NA" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            NEW=$(echo "$ALL_VERSIONS" | grep -Eiv "$VER_SKIP_PATTERN|-" \
                | awk -v curr="$CURRENT" -F. '
                    BEGIN {
                        split(curr,c,".")
                        best=""
                    }
                    /^[0-9]+\.[0-9]+\.[0-9]+$/ {
                        if (best=="" || ($1+0)>(bv[1]+0) || \
                            (($1+0)==(bv[1]+0) && ($2+0)>(bv[2]+0)) || \
                            (($1+0)==(bv[1]+0) && ($2+0)==(bv[2]+0) && ($3+0)>(bv[3]+0))) {
                            if ($1>c[1] || ($1==c[1] && ($2>c[2] || ($2==c[2] && $3>=c[3])))) {
                                best=$0; bv[1]=$1; bv[2]=$2; bv[3]=$3
                            }
                        }
                    }
                    END { print best }
                ')

            if [[ -z "$NEW" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "NA" "SKIPPED (NO NEW VERSION)" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue

            elif [[ "$NEW" == "$CURRENT" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW" "UP-TO-DATE" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi
                        # ✅ ✅ Classification
            update_type=$(classify_version_update "$CURRENT" "$NEW")

            # Validate update type; skip unknown (e.g. same version edge-case)
            case "$update_type" in
                patch|minor|major) ;;
                *)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "SKIPPED (UNKNOWN TYPE)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
            esac

            # ✅ ✅ Preserve prefix
            PREFIX=$(echo "$RANGE" | sed -E 's/^([^0-9]*).*/\1/')
            NEW_RANGE="${PREFIX}${NEW}"

            # ✅ ✅ Per-package checkpoint
            cp package.json package.json.chk
            [ -f package-lock.json ] && cp package-lock.json package-lock.json.chk

            # ✅ ✅ Update correct section
            if [[ "$DEP_TYPE" == "dep" ]]; then
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                '.dependencies[$pkg] = $ver' package.json > package.json.tmp && mv package.json.tmp package.json
            else
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                '.devDependencies[$pkg] = $ver' package.json > package.json.tmp && mv package.json.tmp package.json
            fi

            # ✅ ✅ Try install — count type only on success
            if npm install --include=dev --no-audit --no-fund >/dev/null 2>&1; then

                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW" "UPGRADED ($update_type)" >> "$REPORT"

                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac

            else
                # ✅ ✅ Rollback only this package
                echo "Rollback package: $NAME"

                cp package.json.chk package.json
                [ -f package-lock.json.chk ] && cp package-lock.json.chk package-lock.json

                npm install --include=dev --no-audit --no-fund >/dev/null 2>&1

                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW_RANGE" "FAILED (INSTALL ERROR)" >> "$REPORT"

                ((FAILED_COUNT++))
            fi

            # ✅ Cleanup temp
            rm -f package.json.chk package-lock.json.chk

        done

        # ✅ Cleanup backup (avoid git issue)
        rm -f package.json.bak package-lock.json.bak

        # Summary
        {
            echo "=============================================="
            echo "DEPENDENCY SUMMARY"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed         : $TOTAL_COUNT"
            echo "Upgraded Count (major+minor+patch)  : $UPDATE_COUNT"
            echo "Skipped (pre-release/unknown)       : $SKIPPED_COUNT"
            echo "Failed (Due to compatibility issues): $FAILED_COUNT"
            echo ""
            echo "Only Patch updates                  : $PATCH_COUNT"
            echo "Minor updates                       : $MINOR_COUNT"
            echo "Major Updates (upgraded)            : $MAJOR_COUNT"
            echo "=============================================="

            echo "Date: $(date)"
        } >> "$REPORT"
        
        REPO_TOTAL_COUNT=$((REPO_TOTAL_COUNT + TOTAL_COUNT))
        REPO_UPDATE_COUNT=$((REPO_UPDATE_COUNT + UPDATE_COUNT))
        REPO_SKIPPED_COUNT=$((REPO_SKIPPED_COUNT + SKIPPED_COUNT))
        REPO_FAILED_COUNT=$((REPO_FAILED_COUNT + FAILED_COUNT))
        REPO_PATCH_COUNT=$((REPO_PATCH_COUNT + PATCH_COUNT))
        REPO_MINOR_COUNT=$((REPO_MINOR_COUNT + MINOR_COUNT))
        REPO_MAJOR_COUNT=$((REPO_MAJOR_COUNT + MAJOR_COUNT))

        if [ "$APPDIR" = "." ]; then
            CHANGED_FILES+=("package.json")
            [ -f package-lock.json ] && CHANGED_FILES+=("package-lock.json")
        else
            CHANGED_FILES+=("$APPDIR/package.json")
            [ -f package-lock.json ] && CHANGED_FILES+=("$APPDIR/package-lock.json")
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    elif [ "$TECH_STACK" = "Angular" ]; then
        # ─────────────────────────────────────────────────────────────
        # Angular dependency updater
        # Strategy:
        #   Phase 1 – all @angular/* packages are updated together as a
        #             single atomic group (Angular requires peer-version
        #             alignment across all @angular/* packages).
        #   Phase 2 – every other dependency is updated per-package
        #             with individual checkpoint/rollback, identical to
        #             the NodeJS logic.
        # ─────────────────────────────────────────────────────────────
        if [ ! -f package.json ]; then
            echo "Error: Angular detected but no package.json found in folder: $APPDIR"
            continue
        fi

        printf "%-30s | %-12s | %-12s | %-20s\n" \
            "PACKAGE" "CURRENT" "LATEST" "STATUS" >> "$REPORT"
        printf "%-30s-+-%-12s-+-%-12s-+-%-20s\n" \
            "------------------------------" "------------" "------------" "--------------------" >> "$REPORT"

        NAME_SKIP_PATTERN="react-quill|some-legacy-package"
        VER_SKIP_PATTERN="alpha|beta|rc|preview|canary|snapshot|nightly"

        TOTAL_COUNT=0; UPDATE_COUNT=0; SKIPPED_COUNT=0; FAILED_COUNT=0
        PATCH_COUNT=0; MINOR_COUNT=0; MAJOR_COUNT=0

        cp package.json package.json.bak
        [ -f package-lock.json ] && cp package-lock.json package-lock.json.bak

        # ── Phase 1: group-update all @angular/* packages ────────────
        mapfile -t ANGULAR_PKGS < <(
            jq -r '
            (.dependencies // {} | to_entries[] | select(.key | startswith("@angular/")) | "\(.key)\t\(.value)\tdep"),
            (.devDependencies // {} | to_entries[] | select(.key | startswith("@angular/")) | "\(.key)\t\(.value)\tdev")
            ' package.json
        )

        if [ "${#ANGULAR_PKGS[@]}" -gt 0 ]; then
            echo "Angular group: found ${#ANGULAR_PKGS[@]} @angular/* package(s)"

            # Use @angular/core as the canonical version reference
            ANGULAR_CORE_RANGE=$(jq -r \
                '.dependencies["@angular/core"] // .devDependencies["@angular/core"] // ""' \
                package.json)
            ANGULAR_CORE_CURRENT=$(echo "$ANGULAR_CORE_RANGE" | \
                sed 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')

            if [ -z "$ANGULAR_CORE_CURRENT" ]; then
                echo "Warning: could not determine @angular/core version; skipping Angular group update"
                for ng_entry in "${ANGULAR_PKGS[@]}"; do
                    IFS=$'\t' read -r NG_NAME NG_RANGE _ <<< "$ng_entry"
                    TOTAL_COUNT=$((TOTAL_COUNT+1))
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                        "$NG_NAME" "$NG_RANGE" "N/A" "SKIPPED (NO BASE VER)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                done
            else
                ALL_CORE_VER=$(npm view "@angular/core" versions --json 2>/dev/null | \
                    jq -r 'if type == "array" then .[] else . end' || true)

                ANGULAR_LATEST=$(echo "$ALL_CORE_VER" | grep -Eiv "$VER_SKIP_PATTERN|-" \
                    | awk -v curr="$ANGULAR_CORE_CURRENT" -F. '
                        BEGIN { split(curr,c,"."); best="" }
                        /^[0-9]+\.[0-9]+\.[0-9]+$/ {
                            if (best=="" || ($1+0)>(bv[1]+0) ||
                                (($1+0)==(bv[1]+0) && ($2+0)>(bv[2]+0)) ||
                                (($1+0)==(bv[1]+0) && ($2+0)==(bv[2]+0) && ($3+0)>(bv[3]+0))) {
                                if (($1+0)>(c[1]+0) || \
                                    (($1+0)==(c[1]+0) && ($2+0)>(c[2]+0)) || \
                                    (($1+0)==(c[1]+0) && ($2+0)==(c[2]+0) && ($3+0)>=(c[3]+0))) {
                                    best=$0; bv[1]=$1; bv[2]=$2; bv[3]=$3
                                }
                            }
                        }
                        END { print best }')

                if [ -z "$ANGULAR_LATEST" ] || [ "$ANGULAR_LATEST" = "$ANGULAR_CORE_CURRENT" ]; then
                    # Already up to date
                    for ng_entry in "${ANGULAR_PKGS[@]}"; do
                        IFS=$'\t' read -r NG_NAME NG_RANGE _ <<< "$ng_entry"
                        TOTAL_COUNT=$((TOTAL_COUNT+1))
                        printf "%-30s | %-12s | %-12s | %-20s\n" \
                            "$NG_NAME" "$ANGULAR_CORE_CURRENT" "$ANGULAR_CORE_CURRENT" "UP-TO-DATE" >> "$REPORT"
                        ((SKIPPED_COUNT++))
                    done
                else
                    ANG_UPDATE_TYPE=$(classify_version_update "$ANGULAR_CORE_CURRENT" "$ANGULAR_LATEST")

                    # Checkpoint before group update
                    cp package.json package.json.ng_chk
                    [ -f package-lock.json ] && cp package-lock.json package-lock.json.ng_chk

                    # Apply new version to every @angular/* package
                    for ng_entry in "${ANGULAR_PKGS[@]}"; do
                        IFS=$'\t' read -r NG_NAME NG_RANGE NG_DEP_TYPE <<< "$ng_entry"
                        NG_PREFIX=$(echo "$NG_RANGE" | sed -E 's/^([^0-9]*).*/\1/')
                        NG_NEW_RANGE="${NG_PREFIX}${ANGULAR_LATEST}"
                        if [[ "$NG_DEP_TYPE" == "dep" ]]; then
                            jq --arg p "$NG_NAME" --arg v "$NG_NEW_RANGE" \
                                '.dependencies[$p] = $v' package.json > package.json.tmp \
                                && mv package.json.tmp package.json
                        else
                            jq --arg p "$NG_NAME" --arg v "$NG_NEW_RANGE" \
                                '.devDependencies[$p] = $v' package.json > package.json.tmp \
                                && mv package.json.tmp package.json
                        fi
                    done

                    echo "Testing npm install after @angular/* group update to $ANGULAR_LATEST..."
                    if npm install --include=dev --no-audit --no-fund >/dev/null 2>&1; then
                        # Group install succeeded — log each package
                        for ng_entry in "${ANGULAR_PKGS[@]}"; do
                            IFS=$'\t' read -r NG_NAME NG_RANGE _ <<< "$ng_entry"
                            TOTAL_COUNT=$((TOTAL_COUNT+1))
                            NG_CUR=$(echo "$NG_RANGE" | sed 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
                            if [ -n "$NG_CUR" ] && [ "$NG_CUR" != "$ANGULAR_LATEST" ]; then
                                printf "%-30s | %-12s | %-12s | %-20s\n" \
                                    "$NG_NAME" "$NG_CUR" "$ANGULAR_LATEST" \
                                    "UPGRADED ($ANG_UPDATE_TYPE)" >> "$REPORT"
                                ((UPDATE_COUNT++))
                                case "$ANG_UPDATE_TYPE" in
                                    patch) ((PATCH_COUNT++)) ;;
                                    minor) ((MINOR_COUNT++)) ;;
                                    major) ((MAJOR_COUNT++)) ;;
                                esac
                            else
                                printf "%-30s | %-12s | %-12s | %-20s\n" \
                                    "$NG_NAME" "${NG_CUR:-?}" "$ANGULAR_LATEST" "UP-TO-DATE" >> "$REPORT"
                                ((SKIPPED_COUNT++))
                            fi
                        done
                    else
                        # Group install failed — rollback everything
                        echo "Angular group install failed; rolling back all @angular/* packages"
                        cp package.json.ng_chk package.json
                        [ -f package-lock.json.ng_chk ] && cp package-lock.json.ng_chk package-lock.json
                        npm install --include=dev --no-audit --no-fund >/dev/null 2>&1 || true

                        for ng_entry in "${ANGULAR_PKGS[@]}"; do
                            IFS=$'\t' read -r NG_NAME NG_RANGE _ <<< "$ng_entry"
                            TOTAL_COUNT=$((TOTAL_COUNT+1))
                            NG_CUR=$(echo "$NG_RANGE" | sed 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
                            printf "%-30s | %-12s | %-12s | %-20s\n" \
                                "$NG_NAME" "${NG_CUR:-?}" "$ANGULAR_LATEST" \
                                "FAILED (GROUP INSTALL ERROR)" >> "$REPORT"
                            ((FAILED_COUNT++))
                        done
                    fi
                    rm -f package.json.ng_chk package-lock.json.ng_chk
                fi
            fi
        fi

        # ── Phase 2: per-package update for non-@angular/* deps ──────
        echo "" >> "$REPORT"
        echo "--- NON-ANGULAR DEPENDENCIES ---" >> "$REPORT"
        printf "%-30s | %-12s | %-12s | %-20s\n" \
            "PACKAGE" "CURRENT" "LATEST" "STATUS" >> "$REPORT"
        printf "%-30s-+-%-12s-+-%-12s-+-%-20s\n" \
            "------------------------------" "------------" "------------" "--------------------" >> "$REPORT"

        mapfile -t NON_NG_DEPS < <(
            jq -r '
            (.dependencies // {} | to_entries[]
              | select(.key | startswith("@angular/") | not)
              | "\(.key)\t\(.value)\tdep"),
            (.devDependencies // {} | to_entries[]
              | select(.key | startswith("@angular/") | not)
              | "\(.key)\t\(.value)\tdev")
            ' package.json
        )

        for entry in "${NON_NG_DEPS[@]}"; do
            IFS=$'\t' read -r NAME RANGE DEP_TYPE <<< "$entry"
            TOTAL_COUNT=$((TOTAL_COUNT+1))

            NAME_LC=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
            if [[ "$NAME_LC" =~ $NAME_SKIP_PATTERN ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$RANGE" "-" "SKIPPED (NAMED)" >> "$REPORT"
                ((SKIPPED_COUNT++)); continue
            fi

            # Skip URL/git/file/tarball entries
            if [[ "$RANGE" =~ ^(https?|git\+https?|git\+ssh|git|file|workspace): ]] || \
               [[ "$RANGE" =~ \.(tgz|tar\.gz)$ ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$RANGE" "-" "SKIPPED (URL/FILE)" >> "$REPORT"
                ((SKIPPED_COUNT++)); continue
            fi

            CURRENT=$(echo "$RANGE" | sed 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
            [[ -z "$CURRENT" ]] && { ((SKIPPED_COUNT++)); continue; }

            ALL_VERSIONS=$(npm view "$NAME" versions --json 2>/dev/null | \
                jq -r 'if type == "array" then .[] else . end' || true)
            if [[ -z "$ALL_VERSIONS" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "NA" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++)); continue
            fi

            NEW=$(echo "$ALL_VERSIONS" | grep -Eiv "$VER_SKIP_PATTERN|-" \
                | awk -v curr="$CURRENT" -F. '
                    BEGIN { split(curr,c,"."); best="" }
                    /^[0-9]+\.[0-9]+\.[0-9]+$/ {
                        if (best=="" || ($1+0)>(bv[1]+0) ||
                            (($1+0)==(bv[1]+0) && ($2+0)>(bv[2]+0)) ||
                            (($1+0)==(bv[1]+0) && ($2+0)==(bv[2]+0) && ($3+0)>(bv[3]+0))) {
                            if (($1+0)>(c[1]+0) || \
                                (($1+0)==(c[1]+0) && ($2+0)>(c[2]+0)) || \
                                (($1+0)==(c[1]+0) && ($2+0)==(c[2]+0) && ($3+0)>=(c[3]+0))) {
                                best=$0; bv[1]=$1; bv[2]=$2; bv[3]=$3
                            }
                        }
                    }
                    END { print best }')

            if [[ -z "$NEW" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "NA" "SKIPPED (NO NEW VERSION)" >> "$REPORT"
                ((SKIPPED_COUNT++)); continue
            elif [[ "$NEW" == "$CURRENT" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "UP-TO-DATE" >> "$REPORT"
                ((SKIPPED_COUNT++)); continue
            fi

            update_type=$(classify_version_update "$CURRENT" "$NEW")

            case "$update_type" in
                patch|minor|major) ;;
                *)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                        "$NAME" "$CURRENT" "$NEW" "SKIPPED (UNKNOWN TYPE)" >> "$REPORT"
                    ((SKIPPED_COUNT++)); continue ;;
            esac

            PREFIX=$(echo "$RANGE" | sed -E 's/^([^0-9]*).*/\1/')
            NEW_RANGE="${PREFIX}${NEW}"

            cp package.json package.json.chk
            [ -f package-lock.json ] && cp package-lock.json package-lock.json.chk

            if [[ "$DEP_TYPE" == "dep" ]]; then
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                    '.dependencies[$pkg] = $ver' package.json > package.json.tmp \
                    && mv package.json.tmp package.json
            else
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                    '.devDependencies[$pkg] = $ver' package.json > package.json.tmp \
                    && mv package.json.tmp package.json
            fi

            if npm install --include=dev --no-audit --no-fund >/dev/null 2>&1; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "UPGRADED ($update_type)" >> "$REPORT"
                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac
            else
                echo "Rollback package: $NAME"
                cp package.json.chk package.json
                [ -f package-lock.json.chk ] && cp package-lock.json.chk package-lock.json
                npm install --include=dev --no-audit --no-fund >/dev/null 2>&1
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW_RANGE" "FAILED (INSTALL ERROR)" >> "$REPORT"
                ((FAILED_COUNT++))
            fi
            rm -f package.json.chk package-lock.json.chk
        done

        rm -f package.json.bak package-lock.json.bak

        # Summary
        {
            echo "=============================================="
            echo "DEPENDENCY SUMMARY"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed         : $TOTAL_COUNT"
            echo "Upgraded Count (major+minor+patch)  : $UPDATE_COUNT"
            echo "Skipped (pre-release/unknown)       : $SKIPPED_COUNT"
            echo "Failed (Due to compatibility issues): $FAILED_COUNT"
            echo ""
            echo "Only Patch updates                  : $PATCH_COUNT"
            echo "Minor updates                       : $MINOR_COUNT"
            echo "Major Updates (upgraded)            : $MAJOR_COUNT"
            echo "=============================================="
            echo "Date: $(date)"
        } >> "$REPORT"

        REPO_TOTAL_COUNT=$((REPO_TOTAL_COUNT + TOTAL_COUNT))
        REPO_UPDATE_COUNT=$((REPO_UPDATE_COUNT + UPDATE_COUNT))
        REPO_SKIPPED_COUNT=$((REPO_SKIPPED_COUNT + SKIPPED_COUNT))
        REPO_FAILED_COUNT=$((REPO_FAILED_COUNT + FAILED_COUNT))
        REPO_PATCH_COUNT=$((REPO_PATCH_COUNT + PATCH_COUNT))
        REPO_MINOR_COUNT=$((REPO_MINOR_COUNT + MINOR_COUNT))
        REPO_MAJOR_COUNT=$((REPO_MAJOR_COUNT + MAJOR_COUNT))

        if [ "$APPDIR" = "." ]; then
            CHANGED_FILES+=("package.json")
            [ -f package-lock.json ] && CHANGED_FILES+=("package-lock.json")
        else
            CHANGED_FILES+=("$APPDIR/package.json")
            [ -f package-lock.json ] && CHANGED_FILES+=("$APPDIR/package-lock.json")
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    # elif [[ "${TECH_STACK,,}" == "python" ]]; then
    elif [[ "$(echo "$TECH_STACK" | tr '[:upper:]' '[:lower:]')" == "python" ]]; then
        echo "Running Python dependency major+minor+patch upgrade..."
        
        TOTAL_COUNT=0
        UPDATE_COUNT=0
        SKIPPED_COUNT=0
        FAILED_COUNT=0
        PATCH_COUNT=0
        MINOR_COUNT=0
        MAJOR_COUNT=0

        if command -v python3 &>/dev/null; then
            PYTHON_CMD="python3"
            pip3 install --quiet packaging
        elif command -v python &>/dev/null; then
            PYTHON_CMD="python"
            pip install --quiet packaging
        else
            echo "Python not found."
            continue
        fi

        echo "$PYTHON_CMD"
        echo "Installing required dependencies..."
		$PYTHON_CMD -m pip install --quiet --upgrade pip setuptools wheel packaging toml || true
        
        echo "===================================================================================="
        
        REQ_FILE=$(find . -type f -name "requirements.txt" | head -1)

        if [ -z "$REQ_FILE" ]; then
            echo "requirements.txt not found"
            continue
        fi

        echo "Using requirements file: $REQ_FILE"

        # Create temp directory and pinned file
        TMP_DIR=$(mktemp -d)
        PINNED="$TMP_DIR/pinned.txt"

        echo "TMP_DIR=$TMP_DIR"
        echo "PINNED=$PINNED"

        # Extract only pinned dependencies (==)
        # - Remove UTF-8 BOM from first line if present
        # - Ignore comment lines (#)
        # - Ignore blank lines
        # - Ignore unpinned packages (e.g. azure-functions, werkzeug>=2.0.0)
        sed '1s/^\xEF\xBB\xBF//' "$REQ_FILE" | \
        grep -v '^[[:space:]]*#' | \
        grep -v '^[[:space:]]*$' | \
        grep '==' > "$PINNED"

        if [ ! -s "$PINNED" ]; then
            echo "No pinned dependencies found in $REQ_FILE"
            echo "requirements.txt contents:"
            cat -A "$REQ_FILE"
            continue
        fi

        echo "Pinned dependencies detected:"
        cat "$PINNED"

        # -----------------------------
        # Extract pinned dependencies 
        # -----------------------------
        # grep -E "^[[:space:]]*[A-Za-z0-9_.+-]+(\[[^\]]+\])?[[:space:]]*==[[:space:]]*[0-9][^#;[:space:]]*" \
        #     "$REQ_FILE" > "$PINNED" || true

        declare -A UPDATES

        # SUMMARY="$TMP_DIR/update-summary.txt"

        printf "%-30s | %-12s | %-12s | %-10s\n" \
            "PACKAGE" "CURRENT" "LATEST" "STATUS" >> "$REPORT"
        printf "%-30s-+-%-12s-+-%-12s-+-%-10s\n" \
            "------------------------------" "------------" "------------" "------------------" >> "$REPORT"
            
        # -----------------------------
        # Check PyPI for updates
        # -----------------------------
        # UPDATED: safe loop (won’t skip last line)
        while IFS= read -r dep || [[ -n "$dep" ]]; do
            pkg="${dep%%==*}"
            pkg="$(echo "$pkg" | xargs)"               # UPDATED: trim spaces
            cur="${dep##*==}"
            cur="${cur%,}"; cur="${cur%$'\r'}"         # UPDATED: clean comma/CR

            key="$(echo "$pkg" | tr 'A-Z' 'a-z' | xargs)"

            ((TOTAL_COUNT++))

            JSON="$TMP_DIR/$key.json"
            curl -sSf "https://pypi.org/pypi/$pkg/json" -o "$JSON" || {
                ((SKIPPED_COUNT++))
                printf "%-30s | %-12s | %-12s | %-10s\n" \
                    "$pkg" "$cur" "$cur" "SKIPPED" >> "$REPORT"
                continue
            }
        
        new_ver=$($PYTHON_CMD - "$JSON" "$cur" <<'PY'
import sys, json, re
from packaging.version import Version, InvalidVersion

json_file = sys.argv[1]
current_raw = sys.argv[2]

# Load JSON safely (Windows safe)
with open(json_file, encoding="utf-8") as f:
    data = json.load(f)

# Parse CURRENT version (allow 4.3.1 or 4.3.1.2)
try:
    current = Version(current_raw)
except InvalidVersion:
    sys.exit(0)

cur_rel = current.release
if len(cur_rel) < 3:
    sys.exit(0)

cur_major = cur_rel[0]
cur_minor = cur_rel[1]
cur_patch = cur_rel[2]

def valid_candidate(ver):
    # stable-only + extra tags (snapshot/ea/m1 etc.)
    if re.search(r"(?:a\d+|b\d+|rc\d+|\.dev\d+|\.post\d+|-alpha|-beta|snapshot|preview|ea|cr|m\d+)", ver, re.I):
        return False
    try:
        v = Version(ver)
    except InvalidVersion:
        return False
    return len(v.release) == 3

best = None

for r in data.get("releases", {}):
    if not valid_candidate(r):
        continue
    v = Version(r)

    # ALLOW patch, minor, and major upgrades (any version strictly > current)
    if v > current:
        if best is None or v > best:
            best = v

print(best if best else "")
PY
)
            
        if [ -n "$new_ver" ]; then

            # UPDATED: double stable check (extra safety)
            if ! is_stable_lts "$new_ver"; then
                ((SKIPPED_COUNT++))
                printf "%-30s | %-12s | %-12s | %-18s\n" \
                    "$pkg" "$cur" "$new_ver" "SKIPPED (NON-STABLE)" >> "$REPORT"
                continue
            fi

            update_type=$(classify_version_update "$cur" "$new_ver")

            case "$update_type" in
                patch)
                    ((PATCH_COUNT++))
                    ((UPDATE_COUNT++))
                    UPDATES["$key"]="$new_ver"
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$new_ver" "UPGRADED (PATCH)" >> "$REPORT"
                    ;;
                minor)
                    ((MINOR_COUNT++))
                    ((UPDATE_COUNT++))
                    UPDATES["$key"]="$new_ver"
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$new_ver" "UPGRADED (MINOR)" >> "$REPORT"
                    ;;
                major)
                    ((MAJOR_COUNT++))
                    ((UPDATE_COUNT++))
                    UPDATES["$key"]="$new_ver"
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$new_ver" "UPGRADED (MAJOR)" >> "$REPORT"
                    ;;
                same|invalid|*)
                    ((SKIPPED_COUNT++))
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$cur" "SKIPPED" >> "$REPORT"
                    ;;
            esac
                
        else
            ((SKIPPED_COUNT++))
            printf "%-30s | %-12s | %-12s | %-10s\n" \
                "$pkg" "$cur" "$cur" "SKIPPED" >> "$REPORT"
        fi

        done < "$PINNED"

        {
            echo "=============================================="
            echo "Dependency Update Summary"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed    : $TOTAL_COUNT"
            echo "Upgraded Count (major+minor+patch): $UPDATE_COUNT"
            echo "Skipped (pre-release/unknown)  : $SKIPPED_COUNT"
            echo "Failed  Count                  : $FAILED_COUNT"
            echo "(Due to compatibility issues)"
            echo " "
            echo "Only Patch updates             : $PATCH_COUNT"
            echo "Minor update count             : $MINOR_COUNT"
            echo "Major Updates (upgraded)        : $MAJOR_COUNT"


            echo "=============================================="

            echo "Date: $(date)"
        } >> "$REPORT"

        REPO_TOTAL_COUNT=$((REPO_TOTAL_COUNT + TOTAL_COUNT))
        REPO_UPDATE_COUNT=$((REPO_UPDATE_COUNT + UPDATE_COUNT))
        REPO_SKIPPED_COUNT=$((REPO_SKIPPED_COUNT + SKIPPED_COUNT))
        REPO_FAILED_COUNT=$((REPO_FAILED_COUNT + FAILED_COUNT))

        REPO_PATCH_COUNT=$((REPO_PATCH_COUNT + PATCH_COUNT))
        REPO_MINOR_COUNT=$((REPO_MINOR_COUNT + MINOR_COUNT))
        REPO_MAJOR_COUNT=$((REPO_MAJOR_COUNT + MAJOR_COUNT))

        REQ_BAK="$REQ_FILE.bak.$(date +%s)"
        cp "$REQ_FILE" "$REQ_BAK"

        while IFS= read -r line || [[ -n "$line" ]]; do

            # keep blanks
            [[ -z "${line// }" ]] && { printf '%s\n' "$line"; continue; }

            # keep comments
            [[ "$line" =~ ^[[:space:]]*# ]] && { printf '%s\n' "$line"; continue; }

            # keep unversioned lines unchanged
            if ! [[ "$line" =~ == ]]; then
                printf '%s\n' "$line"
                continue
            fi

            # update only pinned lines safely
            if [[ "$line" =~ ^([[:space:]]*[A-Za-z0-9_.+-]+)([[:space:]]*)==([[:space:]]*)([^#;[:space:]]+)(.*)$ ]]; then
                name="${BASH_REMATCH[1]}"
                pre_sp="${BASH_REMATCH[2]}"
                post_sp="${BASH_REMATCH[3]}"
                suffix="${BASH_REMATCH[5]}"

                key="$(echo "$name" | tr 'A-Z' 'a-z' | xargs)"

                if [[ -n "${UPDATES[$key]:-}" ]]; then
                    printf '%s%s==%s%s\n' "$name" "$pre_sp" "${UPDATES[$key]}" "$suffix"
                else
                    printf '%s\n' "$line"
                fi
            else
                printf '%s\n' "$line"
            fi

        done < "$REQ_BAK" > "$TMP_DIR/new.txt"

        mv "$TMP_DIR/new.txt" "$REQ_FILE"

        if [ "$APPDIR" = "." ]; then
            CHANGED_FILES+=("requirements.txt")
        else
            CHANGED_FILES+=("$APPDIR/requirements.txt")
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    elif [[ "${TECH_STACK,,}" == "maven" ]]; then

        POM="pom.xml"

        if [ ! -f "$POM" ]; then
            echo "Error: Maven detected but no pom.xml found in folder: $APPDIR"
            continue
        fi

        BACKUP="${POM}.bak" 
        
        echo "Spring Boot Parent + Dependency Major+Minor+Patch Updater"
        echo "----------------------------------------------------"

        cp "$POM" "$BACKUP"

        {
            echo "File: $POM"
            echo ""
        } >> "$REPORT"

        NS="http://maven.apache.org/POM/4.0.0"

        TOTAL_COUNT=0
        UPDATE_COUNT=0
        SKIPPED_COUNT=0
        FAILED_COUNT=0

        PATCH_COUNT=0
        MINOR_COUNT=0
        MAJOR_COUNT=0

        # --------------------------------------------------
        # PARENT DEPENDENCY
        # --------------------------------------------------

        echo "--- PARENT DEPENDENCY ---" >> "$REPORT"
        print_table_header >> "$REPORT"

        PARENT_G=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:parent/pom:groupId" "$POM")
        PARENT_A=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:parent/pom:artifactId" "$POM")
        PARENT_V=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:parent/pom:version" "$POM")

        if [[ -n "$PARENT_V" ]]; then

            ((TOTAL_COUNT++))

            LATEST=$(get_latest_version "$PARENT_G" "$PARENT_A") || true

            # if [[ -n "$LATEST" ]] && is_stable_lts "$LATEST" && is_minor_patch_upgrade "$PARENT_V" "$LATEST"; then
            if [[ -n "$LATEST" ]] && is_stable_lts "$LATEST"; then

                update_type=$(classify_version_update "$PARENT_V" "$LATEST")

                case "$update_type" in
                    patch|minor|major) ;;
                    *)
                        print_table_row "$PARENT_A" "$PARENT_V" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                        ((SKIPPED_COUNT++))
                        continue
                        ;;
                esac

                if safe_xml_update "/pom:project/pom:parent/pom:version" "$LATEST" "$PARENT_A" "$PARENT_V"; then
                    print_table_row "$PARENT_A" "$PARENT_V" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                    ((UPDATE_COUNT++))
                    case "$update_type" in
                        patch) ((PATCH_COUNT++)) ;;
                        minor) ((MINOR_COUNT++)) ;;
                        major) ((MAJOR_COUNT++)) ;;
                    esac
                # else: safe_xml_update already logged FAILED and incremented FAILED_COUNT
                fi

            else

                print_table_row "$PARENT_A" "$PARENT_V" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                ((SKIPPED_COUNT++))

            fi

        else
            echo "No parent dependency found" >> "$REPORT"
        fi

        # --------------------------------------------------
        # PROPERTY VERSION DEPENDENCIES
        # --------------------------------------------------

        echo "" >> "$REPORT"
        echo "--- PROPERTY VERSION DEPENDENCIES ---" >> "$REPORT"
        print_table_header >> "$REPORT"

        TOTAL_PROPS=$(xmlstarlet sel -N pom="$NS" -t -v "count(/pom:project/pom:properties/*)" "$POM")

        for ((i=1;i<=TOTAL_PROPS;i++)); do

            PROP_NAME=$(xmlstarlet sel -N pom="$NS" -t -v "name(/pom:project/pom:properties/*[$i])" "$POM")
            PROP_VALUE=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:properties/*[$i]" "$POM")

            [[ "$PROP_NAME" != *version* ]] && continue

            ((TOTAL_COUNT++))

            GROUP=""
            ARTIFACT=""

            # Search in dependencies that reference this property
            TOTAL_DEPS=$(xmlstarlet sel -N pom="$NS" -t -v "count(/pom:project/pom:dependencies/pom:dependency)" "$POM")

            for ((j=1;j<=TOTAL_DEPS;j++)); do

                DEP_VERSION=$(xmlstarlet sel -N pom="$NS" -t -v \
                    "/pom:project/pom:dependencies/pom:dependency[$j]/pom:version" "$POM")

                # Check if this dependency uses the property
                if [[ "$DEP_VERSION" == "\${$PROP_NAME}" ]]; then

                    GROUP=$(xmlstarlet sel -N pom="$NS" -t -v \
                        "/pom:project/pom:dependencies/pom:dependency[$j]/pom:groupId" "$POM")

                    ARTIFACT=$(xmlstarlet sel -N pom="$NS" -t -v \
                        "/pom:project/pom:dependencies/pom:dependency[$j]/pom:artifactId" "$POM")

                    break
                fi
            done

            # If not found in dependencies, check dependencyManagement
            if [[ -z "$GROUP" ]] || [[ -z "$ARTIFACT" ]]; then
                TOTAL_DM_DEPS=$(xmlstarlet sel -N pom="$NS" -t -v "count(/pom:project/pom:dependencyManagement/pom:dependencies/pom:dependency)" "$POM")
                
                for ((j=1;j<=TOTAL_DM_DEPS;j++)); do
                    DM_DEP_VERSION=$(xmlstarlet sel -N pom="$NS" -t -v \
                        "/pom:project/pom:dependencyManagement/pom:dependencies/pom:dependency[$j]/pom:version" "$POM")

                    if [[ "$DM_DEP_VERSION" == "\${$PROP_NAME}" ]]; then
                        GROUP=$(xmlstarlet sel -N pom="$NS" -t -v \
                            "/pom:project/pom:dependencyManagement/pom:dependencies/pom:dependency[$j]/pom:groupId" "$POM")

                        ARTIFACT=$(xmlstarlet sel -N pom="$NS" -t -v \
                            "/pom:project/pom:dependencyManagement/pom:dependencies/pom:dependency[$j]/pom:artifactId" "$POM")

                        break
                    fi
                done
            fi

            # If not found in dependencies or dependencyManagement, check plugins
            if [[ -z "$GROUP" ]] || [[ -z "$ARTIFACT" ]]; then
                TOTAL_PLUGINS=$(xmlstarlet sel -N pom="$NS" -t -v "count(/pom:project/pom:build/pom:plugins/pom:plugin)" "$POM")
                
                for ((j=1;j<=TOTAL_PLUGINS;j++)); do
                    PLUGIN_VERSION=$(xmlstarlet sel -N pom="$NS" -t -v \
                        "/pom:project/pom:build/pom:plugins/pom:plugin[$j]/pom:version" "$POM")

                    if [[ "$PLUGIN_VERSION" == "\${$PROP_NAME}" ]]; then
                        GROUP=$(xmlstarlet sel -N pom="$NS" -t -v \
                            "/pom:project/pom:build/pom:plugins/pom:plugin[$j]/pom:groupId" "$POM")

                        ARTIFACT=$(xmlstarlet sel -N pom="$NS" -t -v \
                            "/pom:project/pom:build/pom:plugins/pom:plugin[$j]/pom:artifactId" "$POM")

                        break
                    fi
                done
            fi

            # If still not found, skip this property
            if [[ -z "$GROUP" ]] || [[ -z "$ARTIFACT" ]]; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "SKIPPED" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            # Get latest version
            LATEST=$(get_latest_version "$GROUP" "$ARTIFACT") || true

            if [[ -z "$LATEST" ]] || ! is_stable_lts "$LATEST"; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            if [[ -z "$LATEST" ]]; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            update_type=$(classify_version_update "$PROP_VALUE" "$LATEST")

            case "$update_type" in
                patch|minor|major) ;;
                *)
                    print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
            esac

            if safe_xml_update "/pom:project/pom:properties/*[name()='$PROP_NAME']" "$LATEST" "$PROP_NAME" "$PROP_VALUE"; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac
            # else: safe_xml_update already logged FAILED and incremented FAILED_COUNT
            fi
        done
            
        # --------------------------------------------------
        # EXPLICIT DEPENDENCIES
        # --------------------------------------------------

        echo "" >> "$REPORT"
        echo "--- EXPLICIT VERSION DEPENDENCIES ---" >> "$REPORT"
        print_table_header >> "$REPORT"

        TOTAL_DEPS=$(xmlstarlet sel -N pom="$NS" -t -v \
            "count(/pom:project/pom:dependencies/pom:dependency)" "$POM")

        for ((i=1;i<=TOTAL_PROPS;i++)); do

            PROP_NAME=$(xmlstarlet sel -N pom="$NS" -t -v "name(/pom:project/pom:properties/*[$i])" "$POM")
            PROP_VALUE=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:properties/*[$i]" "$POM")

            [[ "$PROP_NAME" != *version* ]] && continue

            ((TOTAL_COUNT++))

            GROUP=""
            ARTIFACT=""

            # ---------------- FIX 4 + FIX 2 ----------------
            DEP=$(xmlstarlet sel -N pom="$NS" -t \
            -m "//pom:dependency[pom:version='\${$PROP_NAME}'] \
                | //pom:dependencyManagement//pom:dependency[pom:version='\${$PROP_NAME}'] \
                | //pom:build/pom:plugins/pom:plugin[pom:version='\${$PROP_NAME}'] \
                | //pom:build/pom:pluginManagement/pom:plugins/pom:plugin[pom:version='\${$PROP_NAME}']" \
            -v "concat(pom:groupId,'|',pom:artifactId)" -n "$POM" | head -n1)

            # ---------------- SKIPPED (correct use) ----------------
            if [[ -z "$DEP" ]]; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "SKIPPED" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            GROUP="${DEP%%|*}"
            ARTIFACT="${DEP##*|}"

            # Get latest version
            LATEST=$(get_latest_version "$GROUP" "$ARTIFACT")

            # ---------------- FAILED (important restore) ----------------
            if [[ -z "$LATEST" ]] || ! is_stable_lts "$LATEST"; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            # ---------------- Upgrade logic ----------------

            update_type=$(classify_version_update "$PROP_VALUE" "$LATEST")

            case "$update_type" in
                patch|minor|major) ;;
                *)
                    print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
            esac

            if safe_xml_update "/pom:project/pom:properties/*[name()='$PROP_NAME']" "$LATEST" "$PROP_NAME" "$PROP_VALUE"; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac
            # else: safe_xml_update already logged FAILED and incremented FAILED_COUNT
            fi

        done

        # --------------------------------------------------
        # MAVEN PLUGINS
        # --------------------------------------------------

        echo "" >> "$REPORT"
        echo "--- MAVEN PLUGINS ---" >> "$REPORT"
        print_table_header >> "$REPORT"

        TOTAL_PLUGINS=$(xmlstarlet sel -N pom="$NS" -t -v \
            "count(/pom:project/pom:build/pom:plugins/pom:plugin)" "$POM")

        for ((i=1;i<=TOTAL_PLUGINS;i++)); do

            GROUP=$(xmlstarlet sel -N pom="$NS" -t -v \
                "/pom:project/pom:build/pom:plugins/pom:plugin[$i]/pom:groupId" "$POM")

            ARTIFACT=$(xmlstarlet sel -N pom="$NS" -t -v \
                "/pom:project/pom:build/pom:plugins/pom:plugin[$i]/pom:artifactId" "$POM")

            VERSION=$(xmlstarlet sel -N pom="$NS" -t -v \
                "/pom:project/pom:build/pom:plugins/pom:plugin[$i]/pom:version" "$POM")

            [[ -z "$ARTIFACT" ]] && continue

            ((TOTAL_COUNT++))

            if [[ -z "$VERSION" || $VERSION =~ ^\$\{.*\}$ ]]; then
                print_table_row "$ARTIFACT" "${VERSION:-INHERITED}" "N/A" "PROPERTY" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            LATEST=$(get_latest_version "$GROUP" "$ARTIFACT") || true

            if [[ -z "$LATEST" ]] || ! is_stable_lts "$LATEST"; then
                print_table_row "$ARTIFACT" "$VERSION" "N/A" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            update_type=$(classify_version_update "$VERSION" "$LATEST")

            case "$update_type" in
                patch|minor|major) ;;
                *)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
            esac

            if safe_xml_update "/pom:project/pom:build/pom:plugins/pom:plugin[$i]/pom:version" "$LATEST" "$ARTIFACT" "$VERSION"; then
                print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac
            # else: safe_xml_update already logged FAILED and incremented FAILED_COUNT
            fi

        done

        # ---------------- SUMMARY ----------------
        {
            echo "=============================================="
            echo "Dependency Update Summary"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed    : $TOTAL_COUNT"
            echo "Upgraded Count (major+minor+patch): $UPDATE_COUNT"
            echo "Skipped (pre-release/unknown)  : $SKIPPED_COUNT"
            echo "Failed count                   : $FAILED_COUNT"
            echo "(Due to compatibility issues)"
            echo " "
            echo "Only Patch updates             : $PATCH_COUNT"
            echo "Minor update count             : $MINOR_COUNT"
            echo "Major Updates (upgraded)        : $MAJOR_COUNT"
            echo "=============================================="

            echo "Backup saved as: $BACKUP"
            echo "Report saved as: $REPORT"
            echo "Date: $(date)"
        } >> "$REPORT"
        
        REPO_TOTAL_COUNT=$((REPO_TOTAL_COUNT + TOTAL_COUNT))
        REPO_UPDATE_COUNT=$((REPO_UPDATE_COUNT + UPDATE_COUNT))
        REPO_SKIPPED_COUNT=$((REPO_SKIPPED_COUNT + SKIPPED_COUNT))
        REPO_FAILED_COUNT=$((REPO_FAILED_COUNT + FAILED_COUNT))

        REPO_PATCH_COUNT=$((REPO_PATCH_COUNT + PATCH_COUNT))
        REPO_MINOR_COUNT=$((REPO_MINOR_COUNT + MINOR_COUNT))
        REPO_MAJOR_COUNT=$((REPO_MAJOR_COUNT + MAJOR_COUNT))


        if [ "$APPDIR" = "." ]; then
            CHANGED_FILES+=("pom.xml")
        else
            CHANGED_FILES+=("$APPDIR/pom.xml")
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    elif [[ "${TECH_STACK,,}" == "php" ]]; then
        echo "Running PHP/Composer dependency major+minor+patch upgrade..."

        if [ ! -f "composer.json" ]; then
            echo "Error: PHP detected but no composer.json found in folder: $APPDIR"
            continue
        fi

        if ! command -v composer &>/dev/null; then
            echo "Composer not found. Skipping PHP folder: $APPDIR"
            continue
        fi

        TOTAL_COUNT=0
        UPDATE_COUNT=0
        SKIPPED_COUNT=0
        FAILED_COUNT=0
        PATCH_COUNT=0
        MINOR_COUNT=0
        MAJOR_COUNT=0

        printf "%-30s | %-12s | %-12s | %-20s\n" \
        "PACKAGE" "CURRENT" "LATEST" "STATUS" >> "$REPORT"
        printf "%-30s-+-%-12s-+-%-12s-+-%-20s\n" \
        "------------------------------" "------------" "------------" "--------------------" >> "$REPORT"

        # Packages/constraints to skip (platform packages, plugins, pre-release tags)
        SKIP_PATTERN="alpha|beta|rc|dev-|snapshot"

        cp composer.json composer.json.bak
        [ -f composer.lock ] && cp composer.lock composer.lock.bak

        # Read require + require-dev package names and constraints (skip platform/ext packages)
        mapfile -t DEPS < <(
        jq -r '
        (.require // {} | to_entries[] | select(.key | test("^(php|ext-|composer-plugin-api|composer-runtime-api)") | not) | "\(.key)\t\(.value)\tdep"),
        (."require-dev" // {} | to_entries[] | select(.key | test("^(php|ext-|composer-plugin-api|composer-runtime-api)") | not) | "\(.key)\t\(.value)\tdev")
        ' composer.json
        )

        for entry in "${DEPS[@]}"; do
            IFS=$'\t' read -r NAME RANGE DEP_TYPE <<< "$entry"

            TOTAL_COUNT=$((TOTAL_COUNT+1))

            NAME_LC=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
            if [[ "$NAME_LC" =~ $SKIP_PATTERN ]] || [[ "$RANGE" =~ $SKIP_PATTERN ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$RANGE" "-" "SKIPPED (SKIP PATTERN)" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            # Current installed version, preferring composer.lock (exact) over the constraint
            CURRENT=""
            if [ -f composer.lock ]; then
                CURRENT=$(jq -r --arg pkg "$NAME" \
                    '(.packages + (."packages-dev" // [])) // [] | map(select(.name == $pkg)) | .[0].version // empty' \
                    composer.lock 2>/dev/null)
                CURRENT="${CURRENT#v}"
            fi
            if [[ -z "$CURRENT" || ! "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                CURRENT=$(echo "$RANGE" | sed 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
            fi
            [[ -z "$CURRENT" ]] && { 
                printf "%-30s | %-12s | %-12s | %-20s\n" "$NAME" "$RANGE" "-" "SKIPPED (NO VERSION)" >> "$REPORT"
                ((SKIPPED_COUNT++)); continue
            }
            CURRENT=$(echo "$CURRENT" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')

            # Query Packagist for available versions
            PACKAGIST_JSON=$(curl -sSf "https://repo.packagist.org/p2/${NAME}.json" 2>/dev/null)
            if [[ -z "$PACKAGIST_JSON" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "NA" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            NEW=$(echo "$PACKAGIST_JSON" \
                | jq -r --arg pkg "$NAME" '.packages[$pkg][]?.version // empty' \
                | sed 's/^v//' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
                | grep -Eiv "$SKIP_PATTERN" \
                | awk -v curr="$CURRENT" -F. '
                    BEGIN { split(curr,c,".") }
                    ($1>c[1]) || ($1==c[1] && ($2>c[2] || ($2==c[2] && $3>=c[3]))) { print }
                ' | sort -V | tail -1)

            if [[ -z "$NEW" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "NA" "SKIPPED (NO NEW VERSION)" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            elif [[ "$NEW" == "$CURRENT" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW" "UP-TO-DATE" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            update_type=$(classify_version_update "$CURRENT" "$NEW")

            case "$update_type" in
                patch|minor|major) ;;
                *)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "SKIPPED (UNKNOWN TYPE)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
            esac

            # Preserve constraint prefix (^, ~, >=, etc.)
            PREFIX=$(echo "$RANGE" | sed -E 's/^([^0-9]*).*/\1/')
            NEW_RANGE="${PREFIX}${NEW}"

            cp composer.json composer.json.chk
            [ -f composer.lock ] && cp composer.lock composer.lock.chk

            if [[ "$DEP_TYPE" == "dep" ]]; then
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                '.require[$pkg] = $ver' composer.json > composer.json.tmp && mv composer.json.tmp composer.json
            else
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                '."require-dev"[$pkg] = $ver' composer.json > composer.json.tmp && mv composer.json.tmp composer.json
            fi

            if composer update "$NAME" --no-interaction --no-progress --prefer-dist >/dev/null 2>&1; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW" "UPGRADED ($update_type)" >> "$REPORT"
                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac
            else
                echo "Rollback package: $NAME"
                cp composer.json.chk composer.json
                [ -f composer.lock.chk ] && cp composer.lock.chk composer.lock
                composer update "$NAME" --no-interaction --no-progress --prefer-dist >/dev/null 2>&1 || true

                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW_RANGE" "FAILED (INSTALL ERROR)" >> "$REPORT"
                ((FAILED_COUNT++))
            fi

            rm -f composer.json.chk composer.lock.chk
        done

        rm -f composer.json.bak composer.lock.bak

        {
            echo "=============================================="
            echo "DEPENDENCY SUMMARY"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed         : $TOTAL_COUNT"
            echo "Upgraded Count (major+minor+patch)  : $UPDATE_COUNT"
            echo "Skipped (pre-release/unknown)       : $SKIPPED_COUNT"
            echo "Failed (Due to compatibility issues): $FAILED_COUNT"
            echo ""
            echo "Only Patch updates                  : $PATCH_COUNT"
            echo "Minor updates                       : $MINOR_COUNT"
            echo "Major Updates (upgraded)            : $MAJOR_COUNT"
            echo "=============================================="
            echo "Date: $(date)"
        } >> "$REPORT"

        REPO_TOTAL_COUNT=$((REPO_TOTAL_COUNT + TOTAL_COUNT))
        REPO_UPDATE_COUNT=$((REPO_UPDATE_COUNT + UPDATE_COUNT))
        REPO_SKIPPED_COUNT=$((REPO_SKIPPED_COUNT + SKIPPED_COUNT))
        REPO_FAILED_COUNT=$((REPO_FAILED_COUNT + FAILED_COUNT))
        REPO_PATCH_COUNT=$((REPO_PATCH_COUNT + PATCH_COUNT))
        REPO_MINOR_COUNT=$((REPO_MINOR_COUNT + MINOR_COUNT))
        REPO_MAJOR_COUNT=$((REPO_MAJOR_COUNT + MAJOR_COUNT))

        if [ "$APPDIR" = "." ]; then
            CHANGED_FILES+=("composer.json")
            [ -f composer.lock ] && CHANGED_FILES+=("composer.lock")
        else
            CHANGED_FILES+=("$APPDIR/composer.json")
            [ -f composer.lock ] && CHANGED_FILES+=("$APPDIR/composer.lock")
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    else
        echo "$TECH_STACK TechStack and Skipping patch process for folder: $FOLDER_LABEL"
    fi

    done
    # ---- end of application-folder loop; combined per-repo decision below ----

    cd "$REPO_BASE_DIR" || true

    {
        echo ""
        echo "===================================================="
        echo "Repository Summary"
        echo ""
        echo "Total Dependencies Analyzed : $REPO_TOTAL_COUNT"
        echo "Patch Updates               : $REPO_PATCH_COUNT"
        echo "Minor Updates               : $REPO_MINOR_COUNT"
        echo "Major Updates               : $REPO_MAJOR_COUNT"
        echo "Skipped                     : $REPO_SKIPPED_COUNT"
        echo "Failed                      : $REPO_FAILED_COUNT"
    } >> "$REPORT"

    cat "$REPORT"

    ((TOTAL_REPOS_PACKAGE_COUNT += REPO_TOTAL_COUNT))
    ((TOTAL_REPOS_UPDATED_COUNT += REPO_UPDATE_COUNT))
    ((TOTAL_REPOS_SKIPPED_COUNT += REPO_SKIPPED_COUNT))
    ((TOTAL_REPOS_FAILED_COUNT += REPO_FAILED_COUNT))

    ((TOTAL_REPOS_PATCH_COUNT += REPO_PATCH_COUNT))
    ((TOTAL_REPOS_MINOR_COUNT += REPO_MINOR_COUNT))
    ((TOTAL_REPOS_MAJOR_COUNT += REPO_MAJOR_COUNT))

    if [[ "$REPO_UPDATE_COUNT" -gt 0 || "$REPO_FAILED_COUNT" -gt 0 ]]; then

        if (( REPO_FAILED_COUNT > 0 )); then
            MANUAL_ATTENTION="YES"
        else
            MANUAL_ATTENTION="NO"
        fi

        if (( REPO_UPDATE_COUNT > 0 )); then
            HAS_UPDATE="YES"
        else
            HAS_UPDATE="NO"
        fi

        echo "\"$repo\",\"$MANUAL_ATTENTION\",\"$HAS_UPDATE\",\"$REPO_TOTAL_COUNT\",\"$REPO_UPDATE_COUNT\",\"$REPO_SKIPPED_COUNT\",\"$REPO_FAILED_COUNT\",\"$REPO_PATCH_COUNT\",\"$REPO_MINOR_COUNT\",\"$REPO_MAJOR_COUNT\"" >> "$EXCEL_REPORT"

        echo " $REPO_UPDATE_COUNT Minor updates detected across ${#APP_DIRS[@]} folder(s) → committing and creating PR on $BRANCH_NAME"
        echo "Script Running Successfully"

        push_changes "$reponame" "${CHANGED_FILES[@]}"

        echo "$reponame Pull Request created successfully with ID: - $PR_ID"

    elif (( REPO_UPDATE_COUNT == 0 && REPO_FAILED_COUNT > 0 )); then
        HAS_UPDATE="NO"
        MANUAL_ATTENTION="YES"
        echo "\"$repo\",\"$MANUAL_ATTENTION\",\"$HAS_UPDATE\",\"$REPO_TOTAL_COUNT\",\"$REPO_UPDATE_COUNT\",\"$REPO_SKIPPED_COUNT\",\"$REPO_FAILED_COUNT\",\"$REPO_PATCH_COUNT\",\"$REPO_MINOR_COUNT\",\"$REPO_MAJOR_COUNT\"" >> "$EXCEL_REPORT"
        echo "Warning: Updates failed for $repo"
    else
        HAS_UPDATE="NO"
        MANUAL_ATTENTION="NO"
        echo "\"$repo\",\"$MANUAL_ATTENTION\",\"$HAS_UPDATE\",\"$REPO_TOTAL_COUNT\",\"$REPO_UPDATE_COUNT\",\"$REPO_SKIPPED_COUNT\",\"$REPO_FAILED_COUNT\",\"$REPO_PATCH_COUNT\",\"$REPO_MINOR_COUNT\",\"$REPO_MAJOR_COUNT\"" >> "$EXCEL_REPORT"
        echo "Great: No minor or patch updates found for $repo"
    fi
    echo "Processing of $reponame completed."

    cd "$WORKDIR"

	echo "----------------------Just allover update details----------------------------"
    echo "Repository PR Counts        : $TOTAL_REPOS_PR"
    echo "Total dependencies analyzed : $TOTAL_REPOS_PACKAGE_COUNT"
    echo ""
    
    echo "Successfully Updated        : $TOTAL_REPOS_UPDATED_COUNT"
    echo "Skipped  (up-to-date)       : $TOTAL_REPOS_SKIPPED_COUNT"
    echo "Failed                      : $TOTAL_REPOS_FAILED_COUNT"
    echo ""
    
    echo "Only patch-level update     : $TOTAL_REPOS_PATCH_COUNT"
    echo "Minor update count          : $TOTAL_REPOS_MINOR_COUNT"
    echo "Major Updates (upgraded)     : $TOTAL_REPOS_MAJOR_COUNT"
    echo "--------------------------------------------------------------------------"
   
done  

echo "======================================"
echo " Sending all report on mail processed..."
echo "*Repository Scan Summary:*"

echo "Repository PR Counts        : $TOTAL_REPOS_PR"
echo "Total dependencies analyzed : $TOTAL_REPOS_PACKAGE_COUNT"
echo ""

echo "Successfully Updated        : $TOTAL_REPOS_UPDATED_COUNT"
echo "Skipped  (up-to-date)       : $TOTAL_REPOS_SKIPPED_COUNT"
echo "Failed                      : $TOTAL_REPOS_FAILED_COUNT"
echo "(Due to compatibility issues)"
echo ""

echo "Only patch-level update     : $TOTAL_REPOS_PATCH_COUNT"
echo "Minor update count          : $TOTAL_REPOS_MINOR_COUNT"
echo "Major Updates (upgraded)     : $TOTAL_REPOS_MAJOR_COUNT"
echo ""

# -------------------------------
# Collect attachments
# -------------------------------
EMAIL_SUBJECT="Report: Repo Package Version Update with Nested Folder Support (Major, Minor & Patch) via Automation"
EMAIL_BODY=$(cat <<EOF
Hello Team,

Please find attached the Major, Minor and Patch Update Report for the recent repository scan.

*Repository Scan Summary:*

Repository PR Counts        : $TOTAL_REPOS_PR
Total dependencies analyzed : $TOTAL_REPOS_PACKAGE_COUNT

Successfully Updated        : $TOTAL_REPOS_UPDATED_COUNT
Skipped (up-to-date)        : $TOTAL_REPOS_SKIPPED_COUNT
Failed                      : $TOTAL_REPOS_FAILED_COUNT
(Due to compatibility issues)

Only patch-level update     : $TOTAL_REPOS_PATCH_COUNT
Minor update count          : $TOTAL_REPOS_MINOR_COUNT
Major Updates (upgraded)     : $TOTAL_REPOS_MAJOR_COUNT

The detailed update report for each scanned repository is included as an attachment.
Kindly review the attachment for repository-level update details.

Please let us know if you have any questions or require further information.
EOF
)

if [ -d "$REPORTDIR" ]; then
    echo "Creating ZIP archive..."
  	cd "$(dirname "$REPORTDIR")" || exit 1
  	zip -r "$ZIP_FILE" "$(basename "$REPORTDIR")"
    echo "Zip completed."
else
  echo "Report directory not found: $REPORTDIR"
fi

attachments=()

while IFS= read -r -d '' file; do
  attachments+=("$file")
done < <(find "$REPORTDIR" -maxdepth 1 -type f -print0)

echo "Checking attachments before sending mail..."
# Check file existence
ZIP_EXISTS=false
EXCEL_EXISTS=false

[ -f "$ZIP_FILE" ] && ZIP_EXISTS=true
[ -f "$EXCEL_REPORT" ] && EXCEL_EXISTS=true


# ----------------------------------------
# Decide what to send
# ----------------------------------------

if [ -f "$EXCEL_REPORT" ]; then
    echo "Sending Excel report on mail..."
    send_email_azure_smtp "${MAIL_TO}" "${MAIL_CC}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "$EXCEL_REPORT"

    ### send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "${attachments[@]}" "$EXCEL_REPORT"
    #send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "$EXCEL_REPORT"

    if [ $? -eq 0 ]; then
        echo "Email sent successfully with Excel report."
    else
        echo "ERROR: Failed to send email."
    fi
else
    echo "ERROR: Excel report not found: $EXCEL_REPORT"
    # Fallback — send email without attachment
    send_email_azure_smtp "${MAIL_TO}" "${MAIL_CC}" "$EMAIL_SUBJECT" "${EMAIL_BODY}"
fi    
# if $ZIP_EXISTS && $EXCEL_EXISTS; then
#    echo "Sending ZIP + Excel report..."
#    send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "$ZIP_FILE" "$EXCEL_REPORT"

# elif $ZIP_EXISTS && ! $EXCEL_EXISTS; then
#    echo "Excel missing. Sending only ZIP..."
#    send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "$ZIP_FILE"

# elif ! $ZIP_EXISTS && $EXCEL_EXISTS; then
#    echo "ZIP missing. Sending Excel + individual reports..."
#    send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "${attachments[@]}" "$EXCEL_REPORT"

# else
#    echo "ZIP and Excel both missing. Sending only individual reports..."
#    send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "${attachments[@]}"
# fi

echo "-------------------------------------------------"
echo " All report sent on mail ..."


echo "======================================"
echo " All repositories processed...Done"
echo "======================================"