#!/bin/bash

GITHUB_USER="$GITHUB_USER"
GITHUB_TOKEN="$GITHUB_TOKEN"

BITBUCKET_USER="$BITBUCKET_USER"
BITBUCKET_PASSWORD="$BITBUCKET_PASSWORD"

GITHUB_USER_OTHER="$GITHUB_USER_OTHER"
GITHUB_TOKEN_OTHER="$GITHUB_TOKEN_OTHER"

GIT_USERNAME="Automation VersionUpdate"
GIT_EMAIL="pvnakum7@gmail.com"

NPM_TOKEN="$GITHUB_TOKEN"

BRANCH_NAME=""
FEATURE_BRANCH="security_version_fix_major"

# Update kind applied to .NET/NuGet packages (patch | minor | major | all)
NUGET_MODE="major"

REPO_LIST="${REPO_LIST}"   # Passed as Jenkins string parameter (space separated)
PR_TITLE="Security Vulnerability Fix - Only Major updates (SKip minor/patch updates)"
PR_DESC="This PR contains auto-fixed vulnerabilities via automation."

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
# Repositories that should use SSH
####################################
OTHER_REPOS=(
    "https://github.com/pvnakum7/FastAPI-complete-course-basic-advancemain.git"
    "https://github.com/pvnakum7/signuploginwithnode.git"
)

use_repo_credentials() {

    local repo="${1%/}"

    REPO_GITHUB_USER="$GITHUB_USER"
    REPO_GITHUB_TOKEN="$GITHUB_TOKEN"

    for emu_repo in "${OTHER_REPOS[@]}"; do
        if [[ "${emu_repo%/}" == "$repo" ]]; then

            REPO_GITHUB_USER="$GITHUB_USER_OTHER"
            REPO_GITHUB_TOKEN="$GITHUB_TOKEN_OTHER"

            echo "EMU repository detected: $repo" >&2
            return 0
        fi
    done
}


####################################
# Detect target base branch
####################################
detect_branch() {

    local repo_url="$1"
    local auth_url="$repo_url"

    use_repo_credentials "$repo_url"
    #echo "Branch detection credential for: $repo_url" >&2

    if [[ "$repo_url" =~ github.com ]] && [ -n "$REPO_GITHUB_TOKEN" ]; then
        auth_url="https://${REPO_GITHUB_USER}:${REPO_GITHUB_TOKEN}@${repo_url#https://}"

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

install_dependencies() {

    local app_dir="$1"

    local tech_stack
    local pm

    tech_stack=$(detect_project_tech_stack "$app_dir")
    pm=$(detect_package_manager "$app_dir")

    cd "$app_dir" || return 1

    case "$tech_stack" in

        node)

            case "$pm" in

                yarn)
                    yarn install --silent
                    ;;

                npm)
                    npm install --include=dev --no-audit --no-fund
                    ;;

                pnpm)
                    pnpm install --silent
                    ;;
            esac
            ;;

        python)

            if [ -f requirements.txt ]; then
                pip install -r requirements.txt

            elif [ -f pyproject.toml ]; then
                pip install .

            elif [ -f Pipfile ]; then
                pipenv install
            fi
            ;;
    esac
}

restore_project_files() {

    local APP_DIR="$1"

    local PM
    PM=$(detect_package_manager "$APP_DIR")

    cd "$APP_DIR" || return 1

    case "$PM" in

        yarn)
            git checkout -- package.json yarn.lock
            ;;

        npm)
            git checkout -- package.json package-lock.json
            ;;

        pnpm)
            git checkout -- package.json pnpm-lock.yaml
            ;;
    esac

    git clean -fd
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
# UPDATED: Stable version filter (reject pre-release / unstable tags)
is_stable_lts() {
    local ver
    ver="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

    if [[ "$ver" =~ (^|[._-])(alpha[0-9]*|a[0-9]+|beta[0-9]*|b[0-9]+|rc[0-9]*|cr[0-9]*|m[0-9]+|milestone[0-9]*|ea[0-9]*|eap[0-9]*|preview[0-9]*|pre[0-9]*|pr[0-9]*|snapshot[0-9]*|snap[0-9]*|dev[0-9]*|post[0-9]*|nightly[0-9]*|candidate[0-9]*|cand[0-9]*|experimental[0-9]*|exp[0-9]*|canary[0-9]*|test[0-9]*|testing[0-9]*|incubating[0-9]*|incubator[0-9]*)([._-]|$) ]]; then
        return 1
    fi

    return 0
}

java_is_semver() {
    local ver="$1"

    # Standard semantic version only: 1.2.3
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
java_classify_version_update() {
    local current="$1"
    local latest="$2"

    local c_major c_minor c_patch
    local l_major l_minor l_patch

    # Standard semantic versions
    if [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
       [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

        IFS='.' read -r c_major c_minor c_patch <<< "$current"
        IFS='.' read -r l_major l_minor l_patch <<< "$latest"

    else
        # Adobe / MuleSoft / non-semver versions

        c_major=$(echo "$current" | grep -oE '[0-9]+' | sed -n '1p')
        c_minor=$(echo "$current" | grep -oE '[0-9]+' | sed -n '2p')
        c_patch=$(echo "$current" | grep -oE '[0-9]+' | sed -n '3p')

        l_major=$(echo "$latest" | grep -oE '[0-9]+' | sed -n '1p')
        l_minor=$(echo "$latest" | grep -oE '[0-9]+' | sed -n '2p')
        l_patch=$(echo "$latest" | grep -oE '[0-9]+' | sed -n '3p')
    fi

    c_minor=${c_minor:-0}
    c_patch=${c_patch:-0}

    l_minor=${l_minor:-0}
    l_patch=${l_patch:-0}

    if [[ -z "$c_major" || -z "$l_major" ]]; then
        echo "same"
        return
    fi

    if (( l_major > c_major )); then
        echo "major"
    elif (( l_major == c_major && l_minor > c_minor )); then
        echo "minor"
    elif (( l_major == c_major && l_minor == c_minor && l_patch > c_patch )); then
        echo "patch"
    else
        echo "same"
    fi
}
java_sort_versions() {
    # Works for:
    # 2.18.6
    # 5.3.34.RELEASE
    # 2026.6.26908.20260625T154911Z-260600
    # 9.1.0-magento242ee
    sort -V
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
# Update property version
update_maven_property() {
    local property_name="$1"
    local new_version="$2"
    local artifact="$3"
    local current="$4"

    local xpath="/pom:project/pom:properties/*[local-name()='$property_name']"

    safe_xml_update "$xpath" "$new_version" "$artifact" "$current"
}

# Resolve ${property.name} from pom.xml

get_maven_property_value() {
    local pom="$1"
    local property_name="$2"

    xmlstarlet sel \
        -N pom="$NS" \
        -t \
        -v "/pom:project/pom:properties/*[local-name()='$property_name']" \
        "$pom" 2>/dev/null
}
# --------------------------------------------------
# Fetch versions from Maven metadata
# --------------------------------------------------
fetch_maven_metadata_versions() {
    local repo="$1"
    local groupid="$2"
    local artifact="$3"

    local group_path
    group_path="${groupid//./\/}"

    local url="${repo%/}/$group_path/$artifact/maven-metadata.xml"

    echo "Trying metadata: $url" >&2

    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$url" 2>/dev/null \
        | grep -oP '(?<=<version>).*?(?=</version>)' \
        | while read -r v; do
            is_stable_lts "$v" || continue
            echo "$v"
        done
}
is_valid_maven_version() {
    local val="$1"

    [[ -z "$val" ]] && return 1

    # Skip property references
    [[ "$val" =~ ^\$\{.*\}$ ]] && return 1

    # Must contain at least one digit
    [[ "$val" =~ [0-9] ]] || return 1

    # Reject obvious text values
    [[ "$val" =~ ^(admin|localhost|cloud|UTF-8|utf-8|true|false)$ ]] && return 1

    # Reject prerelease versions
    echo "$val" | grep -Eiq \
    '(alpha|beta|snapshot|preview|milestone|rc[0-9]*|cr[0-9]*|ea[0-9]*|m[0-9]+)' \
    && return 1

    return 0
}
# --------------------------------------------------
# MVNRepository fallback
# Used when metadata does not return versions
# --------------------------------------------------
fetch_mvnrepository_versions() {
    local groupid="$1"
    local artifact="$2"

    local escaped_group
    escaped_group="$(echo "$groupid" | sed 's/\./\\./g')"

    local url="https://mvnrepository.com/artifact/$groupid/$artifact/versions"

    echo "Trying MVNRepository fallback: $url" >&2

    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 -A "Mozilla/5.0" "$url" 2>/dev/null \
        | grep -oE "/artifact/$escaped_group/$artifact/[A-Za-z0-9._+:-]+" \
        | awk -F'/' '{print $NF}' \
        | grep -Ev '^versions$' \
        | sort -u \
        | while read -r v; do
            is_stable_lts "$v" || continue
            echo "$v"
        done
}


# Get latest stable version (across all majors — patch, minor, and major upgrades)
# --------------------------------------------------
# Latest Maven version resolver
# Supports:
# Maven Central
# Adobe
# MuleSoft
# MVNRepository fallback
# --------------------------------------------------
get_latest_version() {
    local groupid="$1"
    local artifact="$2"
    local mode="${3:-all}"          # all | patch_only | minor_only | major_only
    local current_ver="${4:-}"

    local urls=(
        "https://repo.maven.apache.org/maven2"
        "https://repo1.maven.org/maven2"
        "https://repo.adobe.com/nexus/content/groups/public"
        "https://repository.mulesoft.org/releases"
        "https://repository.mulesoft.org/nexus/content/repositories/public"
        "https://maven.anypoint.mulesoft.com/api/v3/maven"
        "https://maven.anypoint.mulesoft.com/api/v2/maven"
    )

    local all_versions=""
    local repo versions latest update_type

    echo "----------------------------------------" >&2
    echo "Resolving latest Maven version" >&2
    echo "GroupId : $groupid" >&2
    echo "Artifact: $artifact" >&2
    echo "Current : $current_ver" >&2
    echo "Mode    : $mode" >&2

    for repo in "${urls[@]}"; do
        versions="$(fetch_maven_metadata_versions "$repo" "$groupid" "$artifact")"

        if [[ -n "$versions" ]]; then
            all_versions+=$'\n'"$versions"
        fi
    done

    all_versions="$(echo "$all_versions" | sed '/^[[:space:]]*$/d' | sort -u)"

    # If metadata failed, use MVNRepository as fallback
    if [[ -z "$all_versions" ]]; then
        versions="$(fetch_mvnrepository_versions "$groupid" "$artifact")"

        if [[ -n "$versions" ]]; then
            all_versions="$versions"
        fi
    fi

    all_versions="$(echo "$all_versions" | sed '/^[[:space:]]*$/d' | sort -u)"

    if [[ -z "$all_versions" ]]; then
        echo "No versions found for $groupid:$artifact" >&2
        return 1
    fi

    case "$mode" in
        major_only)
            latest="$(
                echo "$all_versions" |
                while read -r v; do
                    [[ -z "$v" ]] && continue
                    update_type="$(java_classify_version_update "$current_ver" "$v")"
                    [[ "$update_type" == "major" ]] && echo "$v"
                done | java_sort_versions | tail -1
            )"
            ;;

        minor_only)
            latest="$(
                echo "$all_versions" |
                while read -r v; do
                    [[ -z "$v" ]] && continue
                    update_type="$(java_classify_version_update "$current_ver" "$v")"
                    [[ "$update_type" == "minor" ]] && echo "$v"
                done | java_sort_versions | tail -1
            )"
            ;;

        patch_only)
            latest="$(
                echo "$all_versions" |
                while read -r v; do
                    [[ -z "$v" ]] && continue
                    update_type="$(java_classify_version_update "$current_ver" "$v")"
                    [[ "$update_type" == "patch" ]] && echo "$v"
                done | java_sort_versions | tail -1
            )"
            ;;

        all)
            latest="$(echo "$all_versions" | java_sort_versions | tail -1)"
            ;;

        *)
            latest="$(echo "$all_versions" | java_sort_versions | tail -1)"
            ;;
    esac

    if [[ -z "$latest" ]]; then
        echo "No eligible version found for $groupid:$artifact in mode $mode" >&2
        return 1
    fi

    echo "Selected latest: $latest" >&2
    echo "$latest"
    return 0
}

# ===== .NET / NuGet helpers =====
# NUGET_MODE (patch|minor|major|all) selects which kind of update is applied.
# Sitecore.* packages are read from the Sitecore feed first, everything else from nuget.org first
# (each feed is the fallback for the other).
IFS= read -r -d '' NUGET_PY <<'PY'
import sys, os, re, json, glob, time, urllib.request, urllib.error

NUGET_ORG = os.environ.get("NUGET_ORG_URL", "https://api.nuget.org/v3-flatcontainer").rstrip("/")
SITECORE = os.environ.get("NUGET_SITECORE_URL", "https://nuget.sitecore.com/resources/v3-flatcontainer").rstrip("/")
FILES = ("*.csproj", "*.fsproj", "*.vbproj", "Directory.Packages.props", "Directory.Build.props", "packages.config")
TAG = re.compile(r'<(PackageReference|PackageVersion|GlobalPackageReference)\b([^>]*?)(/?)>', re.S)
CFG = re.compile(r'<package\b([^>]*?)/?>', re.I | re.S)
STABLE = re.compile(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?$')


def read(path):
    raw = open(path, 'rb').read()
    return raw.decode('utf-8-sig', 'replace'), raw.startswith(b'\xef\xbb\xbf')


def write(path, text, bom):
    open(path, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + text.encode('utf-8'))


def attr(s, name):
    m = re.search(r'\b%s\s*=\s*"([^"]*)"' % name, s, re.I)
    return m


def files_in(d):
    out = []
    for g in FILES:
        out += glob.glob(os.path.join(d, g))
    return sorted(set(out))


def scan(path):
    """-> [(name, version, (start, end))] for every package version found in one file."""
    text, _ = read(path)
    found = []
    if os.path.basename(path).lower() == 'packages.config':
        for m in CFG.finditer(text):
            i, v = attr(m.group(1), 'id'), attr(m.group(1), 'version')
            if i and v:
                found.append((i.group(1), v.group(1), (m.start(1) + v.start(1), m.start(1) + v.end(1))))
        return found
    for m in TAG.finditer(text):
        a = m.group(2)
        n = attr(a, 'Include') or attr(a, 'Update')
        if not n:
            continue
        v = attr(a, 'Version')
        if v:
            found.append((n.group(1), v.group(1), (m.start(2) + v.start(1), m.start(2) + v.end(1))))
        elif not m.group(3):
            end = text.find('</%s>' % m.group(1), m.end())
            if end > 0:
                vm = re.search(r'<Version>\s*([^<]+?)\s*</Version>', text[m.end():end])
                if vm:
                    found.append((n.group(1), vm.group(1), (m.end() + vm.start(1), m.end() + vm.end(1))))
    return found


def find_property(files, name):
    for p in files:
        text, _ = read(p)
        m = re.search(r'<%s>\s*([^<$]+?)\s*</%s>' % (re.escape(name), re.escape(name)), text)
        if m:
            return p, m.group(1), (m.start(1), m.end(1))
    return None


def tup(v):
    m = STABLE.match(v)
    if not m:
        return None
    return tuple(int(x) if x else 0 for x in m.groups())


def kind(c, n):
    return 'major' if n[0] > c[0] else 'minor' if n[1] > c[1] else 'patch'


def pick(cur, versions, mode):
    c = [v for v in versions if v > cur]
    if mode == 'patch':
        c = [v for v in c if v[:2] == cur[:2]]
    elif mode == 'minor':
        c = [v for v in c if v[0] == cur[0] and v[1] > cur[1]]
    elif mode == 'major':
        c = [v for v in c if v[0] > cur[0]]
    return max(c) if c else None


_cache = {}


def versions_of(name):
    """-> (dict tuple->string of stable versions, error flag). Sitecore.* try the Sitecore feed first."""
    key = name.lower()
    if key in _cache:
        return _cache[key]
    feeds = [SITECORE, NUGET_ORG] if key.startswith('sitecore.') else [NUGET_ORG, SITECORE]
    failed = False
    for feed in feeds:
        url = '%s/%s/index.json' % (feed, key)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=25) as r:
                    data = json.load(r)
                vs = {}
                for s in data.get('versions', []):
                    t = tup(s)
                    if t and t not in vs:
                        vs[t] = s
                if vs:
                    _cache[key] = (vs, False)
                    return _cache[key]
                break
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    break
                failed = True
                time.sleep(1 + attempt)
            except Exception:
                failed = True
                time.sleep(1 + attempt)
    _cache[key] = ({}, failed)
    return _cache[key]


def plan(mode, d):
    files = files_in(d)
    skip = os.environ.get('NAME_SKIP_PATTERN', '')
    rows = []
    for p in files:
        for name, ver, _ in scan(p):
            e = {'file': p, 'name': name, 'raw': ver, 'op': 'pkg', 'efile': p, 'ename': name, 'group': None}
            if ver.startswith('$(') and ver.endswith(')'):
                prop = ver[2:-1]
                hit = find_property(files, prop)
                if not hit:
                    e.update(status='SKIP', label='SKIPPED (VARIABLE)', cur=ver)
                    rows.append(e)
                    continue
                e.update(op='prop', efile=hit[0], ename=prop, cur=hit[1], group='P:' + prop)
            else:
                e['cur'] = ver
            rows.append(e)
    for e in rows:
        if e.get('status'):
            continue
        cur = tup(e['cur'])
        if skip and re.search(skip, e['name'], re.I):
            e.update(status='SKIP', label='SKIPPED (NAMED)')
        elif cur is None:
            e.update(status='SKIP', label='SKIPPED (RANGE)')
        else:
            vs, err = versions_of(e['name'])
            if not vs:
                e.update(status='FAIL' if err else 'SKIP',
                         label='FAILED (SOURCE ERROR)' if err else 'SKIPPED (NOT FOUND)')
                continue
            e['vs'] = vs
            e['curt'] = cur
            top = max(vs)
            new = pick(cur, list(vs), mode)
            e['latest'] = vs[top] if top > cur else e['cur']
            e['newt'] = new
            if top <= cur:
                e.update(status='UPTODATE', label='UP-TO-DATE')
            elif new is None:
                e.update(status='SKIP', label='SKIPPED (%s)' % kind(cur, top))
            else:
                e.update(status='UPGRADE')
    # Packages that must move together: one MSBuild property, or Sitecore.* packages sharing a version.
    groups = {}
    for e in rows:
        if e.get('status') in ('UPGRADE', 'SKIP', 'UPTODATE') and 'vs' in e:
            g = e['group']
            if g is None and e['name'].lower().startswith('sitecore.') and os.environ.get('SITECORE_ALIGN', 'true') == 'true':
                g = e['group'] = 'S:' + e['cur']
            if g is None:
                g = e['group'] = 'N:%s:%s' % (e['file'], e['name'])
            groups.setdefault(g, []).append(e)
    for g, members in groups.items():
        if len(members) > 1 and any(m['status'] == 'UPGRADE' for m in members):
            common = set(members[0]['vs'])
            for m in members[1:]:
                common &= set(m['vs'])
            target = pick(members[0]['curt'], sorted(common), mode)
            for m in members:
                if target is not None and m['status'] in ('UPGRADE', 'UPTODATE', 'SKIP'):
                    m['newt'] = target
                    m['latest'] = m['vs'][target]
                    m['status'] = 'UPGRADE'
                elif m['status'] == 'UPGRADE':
                    m.update(status='SKIP', label='SKIPPED (INCOMPATIBLE)')
        first = True
        for m in members:
            if m['status'] == 'UPGRADE':
                m['new'] = m['vs'][m['newt']]
                if m['op'] == 'prop' and not first:
                    m['op'] = 'none'
                first = False
    for e in rows:
        st = e.get('status', 'SKIP')
        if st == 'UPGRADE':
            k = kind(e['curt'], e['newt'])
            vals = [st, k, e['name'], e['cur'], e['new'], e['new'], e['group'], e['op'], e['efile'], e['ename'], '-']
        else:
            lat = e.get('latest', e['cur'])
            vals = [st, '-', e['name'], e['cur'], '-', lat, '-', 'none', '-', '-', e.get('label', '-')]
        print('\t'.join(str(v).replace('\t', ' ') for v in vals))


def apply(op, efile, ename, old, new):
    if op == 'none':
        return 0
    text, bom = read(efile)
    if op == 'prop':
        hit = find_property([efile], ename)
        spans = [hit[2]] if hit and hit[1] == old else []
    else:
        spans = [s for n, v, s in scan(efile) if n.lower() == ename.lower() and v == old]
    if not spans:
        return 3
    for a, b in sorted(spans, reverse=True):
        text = text[:a] + new + text[b:]
    write(efile, text, bom)
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'plan':
        plan(sys.argv[2], sys.argv[3])
    elif cmd == 'apply':
        sys.exit(apply(*sys.argv[2:7]))
    elif cmd == 'files':
        print('\n'.join(files_in(sys.argv[2])))
PY

nuget_py() {
    "$PYTHON_CMD" -c "$NUGET_PY" "$@"
}

has_dotnet_files() {
    local d="$1" f
    for f in "$d"/*.csproj "$d"/*.fsproj "$d"/*.vbproj "$d"/Directory.Packages.props "$d"/packages.config; do
        [ -f "$f" ] && return 0
    done
    return 1
}

nuget_restore_snap() {
    local f
    for f in "$NUGET_TMP"/snap/*; do
        [ -f "$f" ] && cp "$f" "./$(basename "$f")"
    done
}

# Applies every planned change of one group (rows of NUGET_ROWS) and proves the folder still restores.
nuget_apply_group() {
    local grp="$1" r st kd name cur new latest g op efile ename label f p extra
    rm -rf "$NUGET_TMP/snap"; mkdir -p "$NUGET_TMP/snap"
    for f in *.csproj *.fsproj *.vbproj Directory.Packages.props Directory.Build.props packages.config packages.lock.json; do
        [ -f "$f" ] && cp "$f" "$NUGET_TMP/snap/$f"
    done
    for r in "${NUGET_ROWS[@]}"; do
        IFS=$'\t' read -r st kd name cur new latest g op efile ename label <<< "$r"
        [ "$st" = "UPGRADE" ] && [ "$g" = "$grp" ] || continue
        if ! nuget_py apply "$op" "$efile" "$ename" "$cur" "$new"; then
            echo "Could not edit $name in $efile" >&2
            nuget_restore_snap
            return 1
        fi
    done
    if command -v dotnet &>/dev/null; then
        extra=""
        [ -f packages.lock.json ] && extra="--force-evaluate"
        for p in *.csproj *.fsproj *.vbproj; do
            [ -f "$p" ] || continue
            if ! dotnet restore "$p" -v q $extra > "$NUGET_TMP/restore.log" 2>&1; then
                tail -5 "$NUGET_TMP/restore.log" >&2
                nuget_restore_snap
                return 1
            fi
        done
    else
        echo "dotnet not found - restore validation skipped for group $grp" >&2
    fi
    return 0
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

pick_major_only_version() {
    local current="$1"
    local versions="$2"

    local c_major
    IFS='.' read -r c_major _ <<< "$current"

    local best=""
    local best_major=-1
    local best_minor=-1
    local best_patch=-1

    while read -r ver; do
        [ -z "$ver" ] && continue

        local v_major v_minor v_patch
        IFS='.' read -r v_major v_minor v_patch <<< "$ver"

        # Skip same or lower major versions
        [ "$v_major" -le "$c_major" ] && continue

        if [ "$v_major" -gt "$best_major" ] || \
           { [ "$v_major" -eq "$best_major" ] && [ "$v_minor" -gt "$best_minor" ]; } || \
           { [ "$v_major" -eq "$best_major" ] && [ "$v_minor" -eq "$best_minor" ] && [ "$v_patch" -gt "$best_patch" ]; }
        then
            best_major="$v_major"
            best_minor="$v_minor"
            best_patch="$v_patch"
            best="$ver"
        fi
    done <<< "$versions"

    echo "$best"
}
#### ---------------Java major-only picker-----------------------------------


pick_major_only_version_java() {
    local current="$1"
    local versions="$2"
    local best=""

    while read -r ver; do
        [[ -z "$ver" ]] && continue

        if [[ "$(java_classify_version_update "$current" "$ver")" == "major" ]]; then
            best+="$ver"$'\n'
        fi

    done <<< "$versions"

    echo "$best" | java_sort_versions | tail -1
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
    [ -f "$d/setup.py" ] && return 0
    [ -f "$d/Pipfile" ] && return 0
    [ -f "$d/composer.json" ] && return 0
    has_dotnet_files "$d" && return 0
    return 1
}

detect_project_tech_stack() {

    local d="$1"

    # Python
    if [ -f "$d/requirements.txt" ] || \
       [ -f "$d/pyproject.toml" ] || \
       [ -f "$d/setup.py" ] || \
       [ -f "$d/Pipfile" ]; then
        echo "Python"
        return
    fi

    # NodeJS
    if [ -f "$d/package.json" ]; then
        echo "NodeJS"
        return
    fi

    # Maven
    if [ -f "$d/pom.xml" ]; then
        echo "Maven"
        return
    fi

    # Gradle
    if [ -f "$d/build.gradle" ] || \
       [ -f "$d/build.gradle.kts" ]; then
        echo "Gradle"
        return
    fi
    # .NET / NuGet
    if has_dotnet_files "$d"; then
        echo "DotNet"
        return
    fi

    echo "unknown"
}

detect_package_manager() {
    local d="$1"
    if [ -f "$d/yarn.lock" ]; then
        echo "yarn"
        return
    fi

    if [ -f "$d/pnpm-lock.yaml" ]; then
        echo "pnpm"
        return
    fi

    if [ -f "$d/package-lock.json" ]; then
        echo "npm"
        return
    fi

    if [ -f "$d/package.json" ]; then
        echo "npm"
        return
    fi

    echo ""
}

detect_python_manifest() {
    local d="$1"

    if [ -f "$d/requirements.txt" ]; then
        echo "requirements.txt"
        return 0
    fi

    if [ -f "$d/pyproject.toml" ]; then
        echo "pyproject.toml"
        return 0
    fi

    if [ -f "$d/setup.py" ]; then
        echo "setup.py"
        return 0
    fi

    if [ -f "$d/Pipfile" ]; then
        echo "Pipfile"
        return 0
    fi

    echo ""
}

# Discovers application folders to process, run from the repo root.
# - The root is included if it has its own supported tech stack.
# - Otherwise, every folder up to 3 levels deep from the root that has a
#   supported tech stack is returned (one entry per application).
discover_app_dirs() {
    local dirs=()

    if has_tech_stack_files "."; then
        dirs+=(".")
    fi

    while IFS= read -r d; do
        d="${d#./}"
        [ -z "$d" ] && continue
        [ "$d" = "." ] && continue
        if has_tech_stack_files "$d"; then
            dirs+=("$d")
        fi
    done < <(find . -mindepth 1 -maxdepth 3 -type d \
        -not -path "*/.git*" -not -path "*/node_modules*" \
        2>/dev/null | sort)

    if [ "${#dirs[@]}" -eq 0 ]; then
        return 1
    fi

    printf '%s\n' "${dirs[@]}"
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
            -H "Authorization: token $REPO_GITHUB_TOKEN" \
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
    
    use_repo_credentials "$repo"
    # echo "repo: $repo"
    export NPM_TOKEN="$REPO_GITHUB_TOKEN"

    ####################################
    # Detect base branch
    ####################################
    BRANCH_NAME=$(detect_branch "$repo")
    echo "DEBUG BRANCH_NAME=[$BRANCH_NAME]"

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
                  "https://${REPO_GITHUB_USER}:$REPO_GITHUB_TOKEN@${repo#https://}" \
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
        echo "$reponame - Major update process starts"
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
        APP_DIR_PATH="$REPO_BASE_DIR/$APPDIR"
        cd "$APPDIR" || continue
    else
        APP_DIR_PATH="$REPO_BASE_DIR"
    fi

    if [ "$APPDIR" = "." ]; then
        FOLDER_LABEL="Root Directory"
    else
        FOLDER_LABEL="Folder-: $APPDIR"
    fi

    {
        echo ""
        echo "===================================================="
        echo "$FOLDER_LABEL"
        echo ""
    } >> "$REPORT"

    echo "Detecting App Technology tech Stack..."
    TECH_STACK="$(detect_project_tech_stack "$APP_DIR_PATH")"

    if [ "$TECH_STACK" = "Unknown" ]; then
        echo "Error: Could not detect application technology for folder: $APPDIR"
        continue
    else
        echo "Application Detected: $TECH_STACK ($FOLDER_LABEL)"
    fi

    echo "Folder path: $APP_DIR_PATH"
    echo "Folder label: $FOLDER_LABEL"

    HAS_UPDATE="NO"
    ####################################
    echo "======================== $reponame ======================================"
    echo "============ Major update process start ========"
    echo "======================================================================================"


    if [ "$TECH_STACK" = "NodeJS" ]; then
        if [ ! -f package.json ]; then
            echo "Error: NodeJS detected but no package.json found in folder: $APPDIR"
            continue
        fi

        TECH_STACK="$(detect_project_tech_stack "$APP_DIR_PATH")"

        PACKAGE_MANAGER="$(detect_package_manager "$APP_DIR_PATH")"

        echo "===================================="
        echo "Folder: $APPDIR"
        echo "Tech Stack: $TECH_STACK"
        echo "Package Manager: $PACKAGE_MANAGER"
        echo "===================================="

        if [ "$TECH_STACK" = "NodeJS" ] && [ -z "$PACKAGE_MANAGER" ]; then
            echo "Unable to detect package manager"
            continue
        fi

        case "$PACKAGE_MANAGER" in
            yarn)
                LOCKFILE="yarn.lock"
                echo "Folder '$APPDIR' will use Yarn"
                ;;
            pnpm)
                LOCKFILE="pnpm-lock.yaml"
                echo "Folder '$APPDIR' will use pnpm"
                ;;
            npm)
                LOCKFILE=""
                if [ -f "package-lock.json" ]; then
                    LOCKFILE="package-lock.json"
                fi
                echo "Folder '$APPDIR' will use npm"
                ;;
            *)
                PACKAGE_MANAGER="npm"
                LOCKFILE=""
                echo "Folder '$APPDIR' fallback to npm"
                ;;
        esac
        echo "Using package manager: $PACKAGE_MANAGER"

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
        if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
            cp "$LOCKFILE" "$LOCKFILE.bak"
        fi

        ## Read all dependencies (including devDependencies)
        #### Read dependencies + type
        mapfile -t DEPS < <(
        jq -r '
        (.dependencies // {} | to_entries[] | "\(.key)\t\(.value)\tdep"),
        (.devDependencies // {} | to_entries[] | "\(.key)\t\(.value)\tdev")
        ' package.json
        )
        export NPM_TOKEN="$REPO_GITHUB_TOKEN"

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

            #### Get available versions
            ALL_VERSIONS=$(npm view "$NAME" versions --json 2>/dev/null | jq -r 'if type == "array" then .[] else . end' || true)
            
            if [[ -z "$ALL_VERSIONS" ]]; then
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "NA" "FAILED" >> "$REPORT"
                ((FAILED_COUNT++))
                continue
            fi

            FILTERED_VERSIONS=$(echo "$ALL_VERSIONS" | grep -Eiv "$VER_SKIP_PATTERN|-" || true)
            NEW=$(pick_major_only_version "$CURRENT" "$FILTERED_VERSIONS")

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
            ### Classification
            update_type=$(classify_version_update "$CURRENT" "$NEW")

            # Validate update type
            case "$update_type" in
                major)
                    ;;
                minor)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "SKIPPED (minor)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
                patch)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "SKIPPED (patch)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
                *)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "SKIPPED (UNKNOWN TYPE)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
            esac

            # ### Preserve prefix
            PREFIX=$(echo "$RANGE" | sed -E 's/^([^0-9]*).*/\1/')
            NEW_RANGE="${PREFIX}${NEW}"

            # ### Per-package checkpoint
            cp package.json package.json.chk
            if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                cp "$LOCKFILE" "$LOCKFILE.chk"
            fi

            # ## Update correct section
            if [[ "$DEP_TYPE" == "dep" ]]; then
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                '.dependencies[$pkg] = $ver' package.json > package.json.tmp && mv package.json.tmp package.json
            else
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                '.devDependencies[$pkg] = $ver' package.json > package.json.tmp && mv package.json.tmp package.json
            fi

            ### Try install — count type only on success
            if install_dependencies; then

                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW" "UPGRADED ($update_type)" >> "$REPORT"

                ((UPDATE_COUNT++))
                case "$update_type" in
                    patch) ((PATCH_COUNT++)) ;;
                    minor) ((MINOR_COUNT++)) ;;
                    major) ((MAJOR_COUNT++)) ;;
                esac

            else
                ### Rollback only this package
                echo "Rollback package: $NAME"

                cp package.json.chk package.json
                if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE.chk" ]; then
                    cp "$LOCKFILE.chk" "$LOCKFILE"
                fi

                install_dependencies

                printf "%-30s | %-12s | %-12s | %-20s\n" \
                "$NAME" "$CURRENT" "$NEW_RANGE" "FAILED (INSTALL ERROR)" >> "$REPORT"

                ((FAILED_COUNT++))
            fi

            ### Cleanup temp
            rm -f package.json.chk
            [ -n "$LOCKFILE" ] && rm -f "$LOCKFILE.chk"

        done

        ### Cleanup backup (avoid git issue)
        rm -f package.json.bak
        [ -n "$LOCKFILE" ] && rm -f "$LOCKFILE.bak"

        # Summary
        {
            echo "=============================================="
            echo "DEPENDENCY SUMMARY"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed         : $TOTAL_COUNT"
            echo "Upgraded Count (patch+minor)  : $UPDATE_COUNT"
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
            if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                CHANGED_FILES+=("$LOCKFILE")
            fi
        else
            CHANGED_FILES+=("$APPDIR/package.json")
            if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                CHANGED_FILES+=("$APPDIR/$LOCKFILE")
            fi
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    # elif [ "$TECH_STACK" = "Angular" ]; then
    elif [[ "$(echo "$TECH_STACK" | tr '[:upper:]' '[:lower:]')" == "angular" ]]; then
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

        TECH_STACK="$(detect_project_tech_stack "$APP_DIR_PATH")"

        PACKAGE_MANAGER="$(detect_package_manager "$APP_DIR_PATH")"

        echo "===================================="
        echo "Folder: $APPDIR"
        echo "Tech Stack-Angular: $TECH_STACK"
        echo "Package Manager: $PACKAGE_MANAGER"
        echo "===================================="

        if [ "$TECH_STACK" = "NODEJS" ] && [ -z "$PACKAGE_MANAGER" ]; then
            echo "Unable to detect package manager"
            continue
        fi

        case "$PACKAGE_MANAGER" in
            yarn)
                LOCKFILE="yarn.lock"
                echo "Folder '$APPDIR' will use Yarn"
                ;;
            pnpm)
                LOCKFILE="pnpm-lock.yaml"
                echo "Folder '$APPDIR' will use pnpm"
                ;;
            npm)
                LOCKFILE=""
                if [ -f "package-lock.json" ]; then
                    LOCKFILE="package-lock.json"
                fi
                echo "Folder '$APPDIR' will use npm"
                ;;
            *)
                PACKAGE_MANAGER="npm"
                LOCKFILE=""
                echo "Folder '$APPDIR' fallback to npm"
                ;;
        esac
        echo "Using package manager: $PACKAGE_MANAGER"

        cp package.json package.json.bak
        if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
            cp "$LOCKFILE" "$LOCKFILE.bak"
        fi

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

                FILTERED_CORE_VERSIONS=$(echo "$ALL_CORE_VER" | grep -Eiv "$VER_SKIP_PATTERN|-" || true)
                ANGULAR_LATEST=$(pick_major_only_version "$ANGULAR_CORE_CURRENT" "$FILTERED_CORE_VERSIONS")

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
                    if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                        cp "$LOCKFILE" "$LOCKFILE.ng_chk"
                    fi

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

                    echo "Testing install after @angular/* group update to $ANGULAR_LATEST..."
                    if install_dependencies; then
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
                        if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE.ng_chk" ]; then
                            cp "$LOCKFILE.ng_chk" "$LOCKFILE"
                        fi
                        install_dependencies || true

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
                    rm -f package.json.ng_chk
                    [ -n "$LOCKFILE" ] && rm -f "$LOCKFILE.ng_chk"
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
                        if (best=="" || ($2+0)>(bv[2]+0) || (($2+0)==(bv[2]+0) && ($3+0)>(bv[3]+0))) {
                            if (($1+0)==(c[1]+0) && (($2+0)>(c[2]+0) || (($2+0)==(c[2]+0) && ($3+0)>(c[3]+0)))) {
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
            
                major)
                    ;;
                minor)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW" "SKIPPED (minor)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
                patch)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                        "$NAME" "$CURRENT" "$NEW" "SKIPPED (patch)" >> "$REPORT"
                    ((SKIPPED_COUNT++)); continue ;;
                
                *)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                        "$NAME" "$CURRENT" "$NEW" "SKIPPED (UNKNOWN TYPE)" >> "$REPORT"
                    ((SKIPPED_COUNT++)); continue ;;
            esac

            PREFIX=$(echo "$RANGE" | sed -E 's/^([^0-9]*).*/\1/')
            NEW_RANGE="${PREFIX}${NEW}"

            cp package.json package.json.chk
            if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                cp "$LOCKFILE" "$LOCKFILE.chk"
            fi

            if [[ "$DEP_TYPE" == "dep" ]]; then
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                    '.dependencies[$pkg] = $ver' package.json > package.json.tmp \
                    && mv package.json.tmp package.json
            else
                jq --arg pkg "$NAME" --arg ver "$NEW_RANGE" \
                    '.devDependencies[$pkg] = $ver' package.json > package.json.tmp \
                    && mv package.json.tmp package.json
            fi

            if install_dependencies; then
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
                if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE.chk" ]; then
                    cp "$LOCKFILE.chk" "$LOCKFILE"
                fi
                install_dependencies
                printf "%-30s | %-12s | %-12s | %-20s\n" \
                    "$NAME" "$CURRENT" "$NEW_RANGE" "FAILED (INSTALL ERROR)" >> "$REPORT"
                ((FAILED_COUNT++))
            fi
            rm -f package.json.chk
            [ -n "$LOCKFILE" ] && rm -f "$LOCKFILE.chk"
        done

        rm -f package.json.bak
        [ -n "$LOCKFILE" ] && rm -f "$LOCKFILE.bak"

        # Summary
        {
            echo "=============================================="
            echo "DEPENDENCY SUMMARY"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed         : $TOTAL_COUNT"
            echo "Upgraded Count (major)            : $UPDATE_COUNT"
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
            if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                CHANGED_FILES+=("$LOCKFILE")
            fi
        else
            CHANGED_FILES+=("$APPDIR/package.json")
            if [ -n "$LOCKFILE" ] && [ -f "$LOCKFILE" ]; then
                CHANGED_FILES+=("$APPDIR/$LOCKFILE")
            fi
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    # elif [[ "${TECH_STACK,,}" == "python" ]]; then
    elif [[ "$(echo "$TECH_STACK" | tr '[:upper:]' '[:lower:]')" == "python" ]]; then
        echo "Running Python dependency major upgrade..."
        echo "Folder '$APPDIR' will use Python dependency handling"
        
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
        
        PYTHON_MANIFEST="$(detect_python_manifest ".")"

        if [ -z "$PYTHON_MANIFEST" ]; then
            echo "No supported Python dependency manifest found in folder: $APPDIR"
            continue
        fi

        PY_IS_TOML=""
        if [ "$PYTHON_MANIFEST" = "requirements.txt" ]; then
            REQ_FILE="requirements.txt"
        elif [ "$PYTHON_MANIFEST" = "pyproject.toml" ]; then
            REQ_FILE="pyproject.toml"
            PY_IS_TOML=1
        else
            echo "Detected Python manifest: $PYTHON_MANIFEST"
            echo "This updater currently supports pinned requirements-based dependency updates."
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

        # pyproject.toml: take the "name==version" strings of [project] / [dependency-groups]
        if [ -n "$PY_IS_TOML" ]; then
            grep -oE '"[A-Za-z0-9_.-]+(\[[^]"]*\])?[[:space:]]*==[[:space:]]*[0-9][^",;[:space:]]*' "$REQ_FILE" \
                | tr -d '"' | sort -u > "$PINNED"
        fi

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
            pkg="${pkg%%\[*}"                          # drop extras: name[extra] -> name
            cur="${dep##*==}"
            cur="${cur%,}"; cur="${cur%$'\r'}"         # UPDATED: clean comma/CR

            key="$(echo "$pkg" | tr 'A-Z' 'a-z' | xargs)"

            ((TOTAL_COUNT++))

            JSON="$TMP_DIR/$key.json"
            curl -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "https://pypi.org/pypi/$pkg/json" -o "$JSON" || {
                ((SKIPPED_COUNT++))
                printf "%-30s | %-12s | %-12s | %-10s\n" \
                    "$pkg" "$cur" "$cur" "SKIPPED" >> "$REPORT"
                continue
            }
        
        new_ver=$($PYTHON_CMD - "$JSON" "$cur" <<'PY'
import sys, json, re
from packaging.version import Version, InvalidVersion
from packaging.specifiers import SpecifierSet

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

cur_rel = tuple(current.release) + (0,) * (3 - len(current.release))

# Interpreter used to judge "Requires-Python" of candidate releases (override: PKGUPDATE_PYTHON_VERSION)
import os
TARGET_PYTHON = os.environ.get("PKGUPDATE_PYTHON_VERSION") or "%d.%d.%d" % sys.version_info[:3]

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
    return 2 <= len(v.release) <= 4

best = None

for r in data.get("releases", {}):
    if not valid_candidate(r):
        continue
    try:
        v = Version(r)
    except InvalidVersion:
        continue

    files = data.get("releases", {}).get(r) or []
    if files and all(f.get("yanked") for f in files):
        continue
    rp = next((f.get("requires_python") for f in files if f.get("requires_python")), None)
    if rp:
        try:
            if not SpecifierSet(rp).contains(TARGET_PYTHON, prereleases=True):
                continue
        except Exception:
            pass
    rel = tuple(v.release) + (0,) * (3 - len(v.release))

    # ALLOW only minor upgrades (same major, higher minor; skip patch-only updates)
    if rel[0] > cur_major:
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
                major)
                    ((MAJOR_COUNT++))
                    ((UPDATE_COUNT++))
                    UPDATES["$key"]="$new_ver"
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$new_ver" "UPGRADED (major)" >> "$REPORT"
                    ;;
                minor)
                    ((SKIPPED_COUNT++))
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$new_ver" "SKIPPED (minor)" >> "$REPORT"
                    ;;
                patch)
                    ((SKIPPED_COUNT++))
                    printf "%-30s | %-12s | %-12s | %-18s\n" \
                        "$pkg" "$cur" "$new_ver" "SKIPPED (patch)" >> "$REPORT"
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
            echo "Upgraded Count (patch+minor) : $UPDATE_COUNT"
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

        if [ -n "$PY_IS_TOML" ]; then
            for k in "${!UPDATES[@]}"; do
                sed -i -E "s/(\"$k(\\[[^]\"]*\\])?[[:space:]]*==[[:space:]]*)[0-9][^\",;[:space:]]*/\1${UPDATES[$k]}/I" "$REQ_FILE"
            done
            # Keep uv.lock in step with the edited pins; undo everything if it cannot be resolved
            if [ -f uv.lock ] && [ "${#UPDATES[@]}" -gt 0 ]; then
                if command -v uv &>/dev/null; then
                    cp uv.lock "$TMP_DIR/uv.lock.chk"
                    if ! uv lock >/dev/null 2>&1; then
                        echo "uv lock failed - reverting $REQ_FILE and uv.lock"
                        cp "$REQ_BAK" "$REQ_FILE"; cp "$TMP_DIR/uv.lock.chk" uv.lock
                        echo "NOTE: uv lock could not resolve the updated pins; $REQ_FILE was left unchanged" >> "$REPORT"
                        UPDATES=()
                    fi
                else
                    echo "uv not found - uv.lock was not refreshed"
                fi
            fi
        fi

        if [ "$APPDIR" = "." ]; then
            CHANGED_FILES+=("${REQ_FILE#./}")
            [ -n "$PY_IS_TOML" ] && [ -f uv.lock ] && CHANGED_FILES+=("uv.lock")
        else
            CHANGED_FILES+=("$APPDIR/${REQ_FILE#./}")
            [ -n "$PY_IS_TOML" ] && [ -f uv.lock ] && CHANGED_FILES+=("$APPDIR/uv.lock")
        fi

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    elif [[ "$(echo "$TECH_STACK" | tr '[:upper:]' '[:lower:]')" == "dotnet" ]]; then
        echo "Running .NET/NuGet dependency major upgrade..."
        echo "Folder '$APPDIR' will use NuGet dependency handling"

        TOTAL_COUNT=0
        UPDATE_COUNT=0
        SKIPPED_COUNT=0
        FAILED_COUNT=0

        PATCH_COUNT=0
        MINOR_COUNT=0
        MAJOR_COUNT=0

        if command -v python3 &>/dev/null; then
            PYTHON_CMD="python3"
        elif command -v python &>/dev/null; then
            PYTHON_CMD="python"
        else
            echo "Python not found."
            continue
        fi

        NUGET_TMP=$(mktemp -d)
        mkdir -p "$NUGET_TMP/orig"
        for f in *.csproj *.fsproj *.vbproj Directory.Packages.props Directory.Build.props packages.config packages.lock.json; do
            [ -f "$f" ] && cp "$f" "$NUGET_TMP/orig/$f"
        done

        if ! NAME_SKIP_PATTERN="react-quill|some-legacy-package" nuget_py plan "$NUGET_MODE" . > "$NUGET_TMP/plan.tsv" 2> "$NUGET_TMP/plan.err"; then
            echo "NuGet analysis failed for folder: $APPDIR"
            cat "$NUGET_TMP/plan.err"
            rm -rf "$NUGET_TMP"
            continue
        fi
        mapfile -t NUGET_ROWS < "$NUGET_TMP/plan.tsv"

        printf "%-30s | %-12s | %-12s | %-20s\n" \
        "PACKAGE" "CURRENT" "LATEST" "STATUS" >> "$REPORT"
        printf "%-30s-+-%-12s-+-%-12s-+-%-20s\n" \
        "------------------------------" "------------" "------------" "--------------------" >> "$REPORT"

        declare -A NUGET_RESULT=()
        for row in "${NUGET_ROWS[@]}"; do
            IFS=$'\t' read -r st kd name cur new latest grp op efile ename label <<< "$row"
            TOTAL_COUNT=$((TOTAL_COUNT+1))
            case "$st" in
                UPTODATE)
                    printf "%-30s | %-12s | %-12s | %-20s\n" "$name" "$cur" "$latest" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                SKIP)
                    printf "%-30s | %-12s | %-12s | %-20s\n" "$name" "$cur" "$latest" "$label" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                FAIL)
                    printf "%-30s | %-12s | %-12s | %-20s\n" "$name" "$cur" "NA" "$label" >> "$REPORT"
                    ((FAILED_COUNT++))
                    ;;
                UPGRADE)
                    if [ -z "${NUGET_RESULT[$grp]:-}" ]; then
                        if nuget_apply_group "$grp"; then NUGET_RESULT[$grp]="ok"; else NUGET_RESULT[$grp]="fail"; fi
                    fi
                    if [ "${NUGET_RESULT[$grp]}" = "ok" ]; then
                        printf "%-30s | %-12s | %-12s | %-20s\n" "$name" "$cur" "$new" "UPGRADED ($kd)" >> "$REPORT"
                        ((UPDATE_COUNT++))
                        case "$kd" in
                            patch) ((PATCH_COUNT++)) ;;
                            minor) ((MINOR_COUNT++)) ;;
                            major) ((MAJOR_COUNT++)) ;;
                        esac
                    else
                        printf "%-30s | %-12s | %-12s | %-20s\n" "$name" "$cur" "$new" "FAILED (INSTALL ERROR)" >> "$REPORT"
                        ((FAILED_COUNT++))
                    fi
                    ;;
            esac
        done

        {
            echo "=============================================="
            echo "DEPENDENCY SUMMARY"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed         : $TOTAL_COUNT"
            echo "Upgraded Count (patch+minor)  : $UPDATE_COUNT"
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

        for f in *.csproj *.fsproj *.vbproj Directory.Packages.props Directory.Build.props packages.config packages.lock.json; do
            [ -f "$f" ] || continue
            if [ ! -f "$NUGET_TMP/orig/$f" ] || ! cmp -s "$f" "$NUGET_TMP/orig/$f"; then
                if [ "$APPDIR" = "." ]; then
                    CHANGED_FILES+=("$f")
                else
                    CHANGED_FILES+=("$APPDIR/$f")
                fi
            fi
        done
        rm -rf "$NUGET_TMP"

        echo "$TECH_STACK application processed for folder: $FOLDER_LABEL"

    #elif [[ "${TECH_STACK,,}" == "Maven" ]]; then
    elif [[ "$(echo "$TECH_STACK" | tr '[:upper:]' '[:lower:]')" == "maven" ]]; then
   
        POM="pom.xml"

        if [ ! -f "$POM" ]; then
            echo "Error: Maven detected but no pom.xml found in folder: $APPDIR"
            continue
        fi

        BACKUP="${POM}.bak" 
        
        echo "Spring Boot Parent + Dependency Major Updater"
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

            LATEST=$(get_latest_version "$PARENT_G" "$PARENT_A" "major_only" "$PARENT_V") || true

            if [[ -n "$LATEST" ]] && is_stable_lts "$LATEST"; then

                update_type=$(java_classify_version_update "$PARENT_V" "$LATEST")

                if [[ "$update_type" == "major" ]]; then

                    if safe_xml_update \
                        "/pom:project/pom:parent/pom:version" \
                        "$LATEST" \
                        "$PARENT_A" \
                        "$PARENT_V"; then
                        print_table_row "$PARENT_A" "$PARENT_V" "$LATEST" "UPGRADED (major)" >> "$REPORT"

                        ((UPDATE_COUNT++))
                        ((MAJOR_COUNT++))
                    fi
                else
                    print_table_row "$PARENT_A" "$PARENT_V" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                fi
            else
                print_table_row "$PARENT_A" "$PARENT_V" "N/A" "UP-TO-DATE" >> "$REPORT"
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

        # TOTAL_PROPS=$(xmlstarlet sel -N pom="$NS" -t -v "count(/pom:project/pom:properties/*)" "$POM")                       ## Used  for debuging
        TOTAL_PROPS=$(xmlstarlet sel -N pom="$NS" -t -v "count(/pom:project/pom:properties/*)" "$POM" 2>/dev/null)

        for ((i=1;i<=TOTAL_PROPS;i++)); do
            ### used For debugging
            # PROP_NAME=$(xmlstarlet sel -N pom="$NS" -t -v "name(/pom:project/pom:properties/*[$i])" "$POM")
            # PROP_VALUE=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:properties/*[$i]" "$POM")

            PROP_NAME=$(xmlstarlet sel -N pom="$NS" -t -v "local-name(/pom:project/pom:properties/*[$i])" "$POM" 2>/dev/null)
            PROP_VALUE=$(xmlstarlet sel -N pom="$NS" -t -v "/pom:project/pom:properties/*[$i]" "$POM" 2>/dev/null)

            # [[ "$PROP_NAME" != *version* ]] && continue
            # [[ -z "$PROP_VALUE" ]] && continue

            [[ -z "$PROP_VALUE" ]] && continue
            is_valid_maven_version "$PROP_VALUE" || continue
            
            ((TOTAL_COUNT++))

            PROP_REF="\${$PROP_NAME}"

            DEP=$(
                xmlstarlet sel -N pom="$NS" -t \
                    -m "//pom:dependency[pom:version='$PROP_REF'] | //pom:dependencyManagement//pom:dependency[pom:version='$PROP_REF'] | //pom:build/pom:plugins/pom:plugin[pom:version='$PROP_REF'] | //pom:build/pom:pluginManagement/pom:plugins/pom:plugin[pom:version='$PROP_REF']" \
                    -v "concat(pom:groupId,'|',pom:artifactId)" -n "$POM" 2>/dev/null |
                    head -n1
            )

            if [[ -z "$DEP" ]]; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "SKIPPED" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            GROUP="${DEP%%|*}"
            ARTIFACT="${DEP##*|}"

            if [[ -z "$ARTIFACT" ]]; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "SKIPPED" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            # Default plugin groupId if plugin groupId is omitted
            if [[ -z "$GROUP" ]]; then
                GROUP="org.apache.maven.plugins"
            fi

            LATEST=$(get_latest_version "$GROUP" "$ARTIFACT" "major_only" "$PROP_VALUE") || true
            update_type=$(java_classify_version_update "$PROP_VALUE" "$LATEST")

            if [[ -z "$LATEST" ]] || ! is_stable_lts "$LATEST"; then
                print_table_row "$PROP_NAME" "$PROP_VALUE" "N/A" "No Updates Available" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            case "$update_type" in
                major)
                    if update_maven_property "$PROP_NAME" "$LATEST" "$PROP_NAME" "$PROP_VALUE"; then
                        print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                        ((UPDATE_COUNT++))
                        ((MAJOR_COUNT++))
                    fi
                    ;;
                patch)
                    print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "SKIPPED (patch)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                minor)
                    print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "SKIPPED (minor)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                *)
                    print_table_row "$PROP_NAME" "$PROP_VALUE" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
            esac
        done

        # --------------------------------------------------
        # EXPLICIT VERSION DEPENDENCIES
        # --------------------------------------------------
        echo "" >> "$REPORT"
        echo "--- EXPLICIT VERSION DEPENDENCIES ---" >> "$REPORT"
        print_table_header >> "$REPORT"

        TOTAL_DEPS=$(xmlstarlet sel -N pom="$NS" -t -v "count(//pom:dependency[pom:version])" "$POM" 2>/dev/null)

        for ((i=1; i<=TOTAL_DEPS; i++)); do

            GROUP=$(xmlstarlet sel -N pom="$NS" -t -v "(//pom:dependency[pom:version])[$i]/pom:groupId" "$POM" 2>/dev/null)
            ARTIFACT=$(xmlstarlet sel -N pom="$NS" -t -v "(//pom:dependency[pom:version])[$i]/pom:artifactId" "$POM" 2>/dev/null)
            VERSION=$(xmlstarlet sel -N pom="$NS" -t -v "(//pom:dependency[pom:version])[$i]/pom:version" "$POM" 2>/dev/null)

            [[ -z "$ARTIFACT" || -z "$VERSION" ]] && continue

            # Skip property-based versions here because already handled above
            if [[ "$VERSION" =~ ^\$\{.*\}$ ]]; then
                continue
            fi

            ((TOTAL_COUNT++))

            LATEST=$(get_latest_version "$GROUP" "$ARTIFACT" "major_only" "$VERSION") || true
            update_type=$(java_classify_version_update "$VERSION" "$LATEST")
            

            if [[ -z "$LATEST" ]] || ! is_stable_lts "$LATEST"; then
                print_table_row "$ARTIFACT" "$VERSION" "N/A" "No Updates Available" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            case "$update_type" in
                major)
                    if safe_xml_update "(//pom:dependency[pom:version])[$i]/pom:version" "$LATEST" "$ARTIFACT" "$VERSION"; then
                        print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                        ((UPDATE_COUNT++))
                        ((MAJOR_COUNT++))
                    fi
                    ;;
                patch)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "SKIPPED (patch)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                minor)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "SKIPPED (minor)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                *)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
            esac
        done

        # --------------------------------------------------
        # MAVEN PLUGINS WITH EXPLICIT VERSION
        # --------------------------------------------------
        echo "" >> "$REPORT"
        echo "--- MAVEN PLUGINS ---" >> "$REPORT"
        print_table_header >> "$REPORT"

        TOTAL_PLUGINS=$(xmlstarlet sel -N pom="$NS" -t -v "count(//pom:plugin[pom:version])" "$POM" 2>/dev/null)

        for ((i=1; i<=TOTAL_PLUGINS; i++)); do

            GROUP=$(xmlstarlet sel -N pom="$NS" -t -v "(//pom:plugin[pom:version])[$i]/pom:groupId" "$POM" 2>/dev/null)
            ARTIFACT=$(xmlstarlet sel -N pom="$NS" -t -v "(//pom:plugin[pom:version])[$i]/pom:artifactId" "$POM" 2>/dev/null)
            VERSION=$(xmlstarlet sel -N pom="$NS" -t -v "(//pom:plugin[pom:version])[$i]/pom:version" "$POM" 2>/dev/null)

            [[ -z "$ARTIFACT" || -z "$VERSION" ]] && continue

            # Skip property-based plugin versions here because already handled above
            if [[ "$VERSION" =~ ^\$\{.*\}$ ]]; then
                print_table_row "$ARTIFACT" "$VERSION" "N/A" "PROPERTY" >> "$REPORT"
                #((SKIPPED_COUNT++))
                continue
            fi

            # Maven default plugin group
            if [[ -z "$GROUP" ]]; then
                GROUP="org.apache.maven.plugins"
            fi

            ((TOTAL_COUNT++))

            LATEST=$(get_latest_version "$GROUP" "$ARTIFACT" "major_only" "$VERSION") || true
            update_type=$(java_classify_version_update "$VERSION" "$LATEST")

            if [[ -z "$LATEST" ]] || ! is_stable_lts "$LATEST"; then
                print_table_row "$ARTIFACT" "$VERSION" "N/A" "No Updates Available" >> "$REPORT"
                ((SKIPPED_COUNT++))
                continue
            fi

            case "$update_type" in
                major)
                    if safe_xml_update "(//pom:plugin[pom:version])[$i]/pom:version" "$LATEST" "$ARTIFACT" "$VERSION"; then
                        print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "UPGRADED ($update_type)" >> "$REPORT"
                        ((UPDATE_COUNT++))
                        ((MAJOR_COUNT++))
                    fi
                    ;;
                patch)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "SKIPPED (patch)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                minor)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "SKIPPED (minor)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
                *)
                    print_table_row "$ARTIFACT" "$VERSION" "$LATEST" "UP-TO-DATE" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    ;;
            esac
        done


        # ---------------- SUMMARY ----------------
        {
            echo "=============================================="
            echo "Dependency Update Summary"
            echo "=============================================="
            echo ""
            echo "Total dependencies analyzed    : $TOTAL_COUNT"
            echo "Upgraded Count (major only)    : $UPDATE_COUNT"
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

#    elif [[ "${TECH_STACK,,}" == "php" ]]; then
    elif [[ "$(echo "$TECH_STACK" | tr '[:upper:]' '[:lower:]')" == "php" ]]; then
        echo "Running PHP/Composer dependency major upgrade..."

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
                    ($1+0)==(c[1]+0) && (($2+0)>(c[2]+0) || (($2+0)==(c[2]+0) && ($3+0)>(c[3]+0))) { print }
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

            # Validate update type
            case "$update_type" in
                major) ;;
                patch)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                        "$NAME" "$CURRENT" "$NEW" "SKIPPED (patch)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
                minor)
                    printf "%-30s | %-12s | %-12s | %-20s\n" \
                        "$NAME" "$CURRENT" "$NEW" "SKIPPED (minor)" >> "$REPORT"
                    ((SKIPPED_COUNT++))
                    continue
                    ;;
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
            echo "Upgraded Count (patch+minor)  : $UPDATE_COUNT"
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

        echo " $REPO_UPDATE_COUNT Major updates detected across ${#APP_DIRS[@]} folder(s) → committing and creating PR on $BRANCH_NAME"
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
        echo "Great: No Major updates found for $repo"
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
EMAIL_SUBJECT="Report: Only Major Repo Package Version Update via Automation"
EMAIL_BODY=$(cat <<EOF
Hello Team,

Please find attached the Only Major Update Report for the recent repository scan.

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
    ### send_email_azure_smtp "${MAIL_TO}" "$EMAIL_SUBJECT" "${EMAIL_BODY}" "$EXCEL_REPORT"

    if [ $? -eq 0 ]; then
        echo "Email sent successfully with Excel report."
    else
        echo "ERROR: Failed to send email."
    fi
else
    echo "ERROR: Excel report not found: $EXCEL_REPORT"
    ### Fallback — send email without attachment
    # send_email_azure_smtp "${MAIL_TO}" "${MAIL_CC}" "$EMAIL_SUBJECT" "${EMAIL_BODY}"
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
