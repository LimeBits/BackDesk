#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITEA_BASE_URL="${GITEA_BASE_URL:-http://192.168.31.102:8418}"
GITEA_OWNER="${GITEA_OWNER:-brucetso}"
GITEA_REPO="${GITEA_REPO:-BackDesk}"
GITHUB_OWNER="${GITHUB_OWNER:-LimeBits}"
GITHUB_REPO="${GITHUB_REPO:-BackDesk}"
GITHUB_PROXY="${GITHUB_PROXY:-http://127.0.0.1:7897}"
GITHUB_CURL_ARGS=()
GITEA_CURL_ARGS=(--noproxy '*')
TAGS=("$@")

if [[ -n "${GITHUB_PROXY}" && "${GITHUB_PROXY}" != "none" ]]; then
    GITHUB_CURL_ARGS=(--proxy "${GITHUB_PROXY}")
else
    GITHUB_CURL_ARGS=(--noproxy '*')
fi

if [[ ${#TAGS[@]} -eq 0 ]]; then
    TAGS=(v0.2.6 v0.2.7 v0.2.8)
fi

cd "${ROOT_DIR}"

if [[ -z "${GITEA_TOKEN:-}" ]]; then
    GITEA_TOKEN="$(
        printf 'protocol=http\nhost=%s\n\n' "${GITEA_BASE_URL#http://}" |
        git credential fill |
        awk -F= '$1=="password"{print $2}'
    )"
fi

if [[ -z "${GITEA_TOKEN:-}" ]]; then
    printf '请先设置 GITEA_TOKEN，或确保 git credential 里有 Gitea token。\n' >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

printf '→ 推送缺失 tag 到 Gitea...\n'
git push origin "${TAGS[@]}"

for tag in "${TAGS[@]}"; do
    printf '\n== 同步 %s ==\n' "${tag}"

    github_release="${WORK_DIR}/${tag}-github.json"
    gitea_release="${WORK_DIR}/${tag}-gitea.json"
    assets_file="${WORK_DIR}/${tag}-assets.txt"

    curl "${GITHUB_CURL_ARGS[@]}" -sS -L \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${tag}" \
        -o "${github_release}"

    python3 - "${github_release}" "${assets_file}" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
if "message" in release and release.get("message") == "Not Found":
    raise SystemExit("GitHub release not found")
print(release.get("name") or release.get("tag_name"))
with open(sys.argv[2], "w") as f:
    for asset in release.get("assets", []):
        f.write(asset["name"] + "\t" + asset["browser_download_url"] + "\n")
PY

    release_name="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("name") or r.get("tag_name"))' "${github_release}")"
    release_body="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("body") or "")' "${github_release}")"
    payload="${WORK_DIR}/${tag}-payload.json"
    python3 - "${tag}" "${release_name}" "${release_body}" "${payload}" <<'PY'
import json, sys
tag, name, body, out = sys.argv[1:5]
json.dump({
    "tag_name": tag,
    "target_commitish": "main",
    "name": name,
    "body": body,
    "draft": False,
    "prerelease": False,
}, open(out, "w"))
PY

    http_status="$(
        curl "${GITEA_CURL_ARGS[@]}" -sS -o "${gitea_release}" -w '%{http_code}' \
            -H "Authorization: token ${GITEA_TOKEN}" \
            "${GITEA_BASE_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}/releases/tags/${tag}"
    )"

    if [[ "${http_status}" == "404" ]]; then
        http_status="$(
            curl "${GITEA_CURL_ARGS[@]}" -sS -o "${gitea_release}" -w '%{http_code}' \
                -X POST \
                -H "Authorization: token ${GITEA_TOKEN}" \
                -H 'Content-Type: application/json' \
                --data @"${payload}" \
                "${GITEA_BASE_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}/releases"
        )"
    fi

    if [[ "${http_status}" != "200" && "${http_status}" != "201" ]]; then
        printf 'Gitea release 创建/查询失败: %s HTTP %s\n' "${tag}" "${http_status}" >&2
        cat "${gitea_release}" >&2
        exit 1
    fi

    release_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${gitea_release}")"
    existing_assets="${WORK_DIR}/${tag}-gitea-existing-assets.json"
    curl "${GITEA_CURL_ARGS[@]}" -sS \
        -H "Authorization: token ${GITEA_TOKEN}" \
        "${GITEA_BASE_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}/releases/${release_id}" \
        -o "${existing_assets}"

    while IFS=$'\t' read -r name url; do
        [[ -z "${name}" || -z "${url}" ]] && continue

        local_asset="${WORK_DIR}/${name}"
        printf '→ 下载 GitHub 资产: %s\n' "${name}"
        curl "${GITHUB_CURL_ARGS[@]}" -sS -L "${url}" -o "${local_asset}"

        existing_asset_id="$(
            python3 - "${existing_assets}" "${name}" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
target = sys.argv[2]
for asset in release.get("assets", []) or []:
    if asset.get("name") == target:
        print(asset.get("id"))
        break
PY
        )"

        if [[ -n "${existing_asset_id}" ]]; then
            printf '→ 删除 Gitea 旧资产: %s\n' "${name}"
            curl "${GITEA_CURL_ARGS[@]}" -sS -X DELETE \
                -H "Authorization: token ${GITEA_TOKEN}" \
                "${GITEA_BASE_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}/releases/${release_id}/assets/${existing_asset_id}" \
                >/dev/null
        fi

        printf '→ 上传到 Gitea: %s\n' "${name}"
        upload_status="$(
            curl "${GITEA_CURL_ARGS[@]}" -sS -o "${WORK_DIR}/${tag}-${name}-upload.json" -w '%{http_code}' \
                -X POST \
                -H "Authorization: token ${GITEA_TOKEN}" \
                -F "attachment=@${local_asset}" \
                "${GITEA_BASE_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}/releases/${release_id}/assets?name=${name}"
        )"

        if [[ "${upload_status}" != "201" ]]; then
            printf 'Gitea asset 上传失败: %s HTTP %s\n' "${name}" "${upload_status}" >&2
            cat "${WORK_DIR}/${tag}-${name}-upload.json" >&2
            exit 1
        fi
    done < "${assets_file}"
done

printf '\n✓ 缺失版本同步完成。\n'
