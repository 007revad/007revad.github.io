#!/bin/bash
          REPO_DIR=spkrepo_test

          set -euo pipefail
          mkdir -p "${REPO_DIR}/thumbnails"

          # ------------------------------------------------------------------ #
          # Helper: sum download counts for all .spk assets across all releases.
          # Usage: get_total_downloads <user> <repo>
          # ------------------------------------------------------------------ #
          get_total_downloads() {
            local user="$1"
            local repo="$2"
            local total=0
            local page=1
            while true; do
              local page_data
              page_data=$(curl -fsSL \
                -H "Authorization: Bearer ${GH_TOKEN}" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/${user}/${repo}/releases?per_page=100&page=${page}")
              local page_count
              page_count=$(jq 'length' <<< "$page_data")
              if [[ "$page_count" -eq 0 ]]; then break; fi
              local page_total
              page_total=$(jq -r '[.[].assets[] | select(.name | test("\\.spk$"; "i")) |
                .download_count] | add // 0' <<< "$page_data" 2>/dev/null)                
              total=$(( total + page_total )) || true
              if [[ "$page_count" -lt 100 ]]; then break; fi
              (( page++ ))
            done
            printf '%s\n' "$total"
          }

          # ------------------------------------------------------------------ #
          # Helper: extract a named file from a remote SPK via streaming tar.
          # SPKs are uncompressed tars. INFO is near the start of the archive
          # so a 3 MB range is sufficient to reach it.
          #
          # Usage: fetch_info_from_spk <spk_url>
          # Output: raw INFO file contents printed to stdout
          # ------------------------------------------------------------------ #
          fetch_info_from_spk() {
            local url="$1"
            curl -fsSL --globoff --range 0-3145727 "${url}" | tar -xOf - "INFO" 2>/dev/null
          }

          # ------------------------------------------------------------------ #
          # Helper: extract a single key from INFO content.
          # Strips surrounding single or double quotes.
          #
          # Usage: info_get <info_content> <key>
          # ------------------------------------------------------------------ #
          info_get() {
            local info="$1"
            local key="$2"
            echo "$info" | grep -m1 "^${key}=" | sed 's/^[^=]*=//;s/^["\x27]//;s/["\x27]$//'
          }

          # ------------------------------------------------------------------ #
          # Helper: return the version currently recorded in index.json for a
          # given package name. Returns empty string if not found.
          #
          # Usage: current_version <pkg>
          # ------------------------------------------------------------------ #
          current_version() {
            local pkg="$1"
            if [[ -f ${REPO_DIR}/index.json ]]; then
              jq -r --arg p "$pkg" \
                '.packages[] | select(.package == $p) | .version' \
                ${REPO_DIR}/index.json | head -1
            fi
          }

          # ------------------------------------------------------------------ #
          # Helper: update the thumbnail for a package, but only when the
          # package version has changed since the last run.
          #
          # Icon source priority (stops at first success):
          #   1. https://raw.githubusercontent.com/<user>/<repo>/HEAD/PACKAGE_ICON_256.PNG
          #   2. https://raw.githubusercontent.com/<user>/<repo>/HEAD/synology/PACKAGE_ICON_256.PNG
          #   3. Full SPK download — tar-extract PACKAGE_ICON_256.PNG
          #
          # Resizes the icon to 120x120 and writes
          # <repo_dir>/thumbnails/<thumb_key>_120.png.
          #
          # Usage: maybe_update_thumbnail <spk_url> <pkg> <new_version> <thumb_key> <user> <repo>
          # ------------------------------------------------------------------ #
          maybe_update_thumbnail() {
            local spk_url="$1"
            local pkg="$2"
            local new_version="$3"
            local thumb_key="${4:-$pkg}"
            local user="$5"
            local repo="$6"
            local is_beta="${7:-false}"

            local dest="${REPO_DIR}/thumbnails/${thumb_key}_120.png"
            local old_version
            old_version=$(current_version "${pkg}")

            # Skip if thumbnail already exists and version has not changed
            if [[ -f "${dest}" && "${old_version}" == "${new_version}" ]]; then
              echo "INFO: Thumbnail for ${thumb_key} is current (${new_version}) — skipping." >&2
              return
            fi

            echo "INFO: Updating thumbnail for ${thumb_key} (${old_version:-new} -> ${new_version})." >&2

            local tmp_icon
            tmp_icon=$(mktemp --suffix=.png)

            # ------------------------------------------------------------------
            # Try repo tree locations first (fast, no SPK download needed).
            # Fall back to full SPK download if neither is found.
            # ------------------------------------------------------------------
            local icon_fetched=0
            local raw_base="https://raw.githubusercontent.com/${user}/${repo}/HEAD"

            for icon_url in \
                "${raw_base}/PACKAGE_ICON_256.PNG" \
                "${raw_base}/synology/PACKAGE_ICON_256.PNG"; do
              local http_status
              http_status=$(curl -sSL --globoff -o "${tmp_icon}" \
                -w "%{http_code}" "${icon_url}" 2>/dev/null)
              if [[ "$http_status" == "200" && -s "${tmp_icon}" ]]; then
                echo "INFO: Got icon from ${icon_url}" >&2
                icon_fetched=1
                break
              fi
            done

            if [[ "$icon_fetched" -eq 0 ]]; then
              echo "INFO: Icon not in repo tree — extracting from SPK (full download): $(basename "${spk_url}")" >&2
              if ! curl -fsSL --globoff "${spk_url}" \
                  | tar -xOf - "PACKAGE_ICON_256.PNG" > "${tmp_icon}" 2>/dev/null \
                  || [[ ! -s "${tmp_icon}" ]]; then
                echo "WARNING: Could not obtain PACKAGE_ICON_256.PNG for ${thumb_key}" >&2
                rm -f "${tmp_icon}"
                return
              fi
            fi

            # Resize to 120x120, fitting within the canvas
            if [[ "${is_beta}" == "true" ]]; then
              /usr/bin/convert "${tmp_icon}" \
               -resize 120x120 \
               -gravity center \
               -background none \
               -extent 120x120 \
               -gravity SouthEast \
               -fill white \
               -stroke red \
               -strokewidth 1 \
               -pointsize 16 \
               -annotate +2+2 "BETA" \
               "${dest}"
            else
              /usr/bin/convert "${tmp_icon}" \
               -resize 120x120 \
               -gravity center \
               -background none \
               -extent 120x120 \
               "${dest}"
            fi

            rm -f "${tmp_icon}"
            echo "INFO: Wrote ${dest}" >&2
          }

          # ------------------------------------------------------------------ #
          # Helper: fetch latest release SPKs for a repo and emit one
          # index.json entry per unique SPK.
          #
          # Fetches both the latest full release and the latest pre-release
          # (if they differ). Pre-release SPKs are always emitted with
          # beta=true, overriding whatever the INFO file says.
          #
          # Deduplication rules:
          #   - If a noarch SPK exists for a firmware range, it takes that range
          #     exclusively and all arch-specific SPKs for the same range are
          #     skipped (noarch wins).
          #   - If no noarch exists, each arch gets its own entry (e.g. x86_64,
          #     armv8, armv7 all with the same firmware range are all emitted).
          #   - Duplicate SPKs with identical pkg+version+arch+firmware range
          #     are skipped (safety net for repos that accidentally ship two
          #     identically-named assets).
          #
          # For repos with legitimate multiple SPKs (e.g. one per DSM version
          # with different os_min_ver/os_max_ver), each produces its own entry.
          #
          # Thumbnails are updated only when the package version has changed.
          #
          # Usage: make_entries <user> <repo> [noreleases]
          # ------------------------------------------------------------------ #
          make_entries() {
            local user="$1"
            local repo="$2"
            local changelog_spec="${3:-}"
            local noreleases="${4:-}"
            local tag version=""

            if [[ -z "$noreleases" ]]; then
                # Fetch recent releases and pick the latest full release and
                # latest pre-release separately (they may be the same release).
                local recent_releases
                recent_releases=$(curl -fsSL \
                  -H "Authorization: Bearer ${GH_TOKEN}" \
                  -H "Accept: application/vnd.github+json" \
                  "https://api.github.com/repos/${user}/${repo}/releases?per_page=20")

                local latest_release latest_prerelease
                latest_release=$(   jq '[.[] | select(.prerelease == false)] | .[0] // empty' <<< "$recent_releases")
                latest_prerelease=$( jq --argjson r "${latest_release:-null}" '
                  def parse_ver: ltrimstr("v") | gsub("-"; ".") | split(".") | map(tonumber? // 0);
                  [.[] | select(.prerelease == true)] | .[0] |
                  if . != null and ($r == null or
                    (.tag_name | parse_ver) > ($r.tag_name | parse_ver)
                  )
                  then . else empty end' <<< "$recent_releases")

                echo "DEBUG latest_prerelease tag=$(jq -r '.tag_name // "empty"' <<< "${latest_prerelease:-null}")" >&2
                echo "DEBUG parse_ver check: $(jq -n '
                  def parse_ver: ltrimstr("v") | split("[-.]") | map(tonumber? // 0);
                  {
                    prerelease: ("v1.5.99.3-beta" | parse_ver),
                    stable: ("v1.5.2" | parse_ver),
                    result: (("v1.5.99.3-beta" | parse_ver) > ("v1.5.2" | parse_ver))
                  }')" >&2

                # Combine into a deduplicated array of releases to process
                local releases_to_process
                releases_to_process=$(jq -n \
                  --argjson r  "${latest_release:-null}" \
                  --argjson pr "${latest_prerelease:-null}" \
                  '[$r, $pr] | map(select(. != null)) | unique_by(.id)')

                echo "DEBUG ${user}/${repo} releases_to_process:" >&2
                jq -r '.[] | "\(.tag_name) prerelease=\(.prerelease)"' <<< "$releases_to_process" >&2

                if [[ $(jq 'length' <<< "$releases_to_process") -eq 0 ]]; then
                  echo "WARNING: No releases found for ${user}/${repo}" >&2
                  return
                fi

                # Use the latest full release tag as the canonical version;
                # fall back to the pre-release tag if there is no full release.
                tag=$(jq -r '
                  (map(select(.prerelease == false)) | .[0].tag_name) //
                  (.[0].tag_name) //
                  empty' <<< "$releases_to_process")
                version="${tag#v}"

                local download_count
                download_count=$(get_total_downloads "${user}" "${repo}")

                # Collect all .spk asset URLs from both releases, noarch first
                local all_spk_urls=()
                while IFS= read -r spk_url; do
                  all_spk_urls+=( "$spk_url" )
                done < <(jq -r '
                  [.[].assets[] | select(.name | test("\\.spk$"; "i"))] |
                  sort_by(if (.name | test("noarch"; "i")) then 0 else 1 end) |
                  .[].browser_download_url' <<< "$releases_to_process")

                if [[ ${#all_spk_urls[@]} -eq 0 ]]; then
                  echo "WARNING: No .spk assets found in ${user}/${repo} ${tag}" >&2
                  return
                fi
            else
                # No releases — find .spk files directly in the repo file tree.
                # download_count will be 0 (no releases = no release download stats).
                local download_count=0
                local releases_to_process="[]"

                local all_spk_urls=()
                while IFS= read -r spk_url; do
                  all_spk_urls+=( "$spk_url" )
                done < <(curl -fsSL \
                  -H "Authorization: Bearer ${GH_TOKEN}" \
                  -H "Accept: application/vnd.github+json" \
                  "https://api.github.com/repos/${user}/${repo}/git/trees/HEAD?recursive=1" \
                  | jq -r '
                    [.tree[] | select(.type == "blob" and (.path | test("\\.spk$"; "i")))] |
                    sort_by(if (.path | test("noarch"; "i")) then 0 else 1 end) |
                    .[].path' \
                  | grep -v '\[' \
                  | sed 's| |%20|g; s|^|https://raw.githubusercontent.com/'"${user}"'/'"${repo}"'/HEAD/|')

                if [[ ${#all_spk_urls[@]} -eq 0 ]]; then
                  echo "WARNING: No .spk files found in ${user}/${repo} file tree" >&2
                  return
                fi
            fi

            # Fetch raw changelog content once for this repo.
            local change_raw=""
            if [[ -n "$changelog_spec" ]]; then
              for branch in main master; do
                local try_url="https://raw.githubusercontent.com/${user}/${repo}/${branch}/${changelog_spec##*:}"
                # changelog_spec may be bare filename or "6:path 7:path" — try bare first
                # (DSM-split paths are resolved per-SPK below)
                if [[ "$changelog_spec" != *:* ]]; then
                  change_raw=$(curl -sSL --max-time 10 -w "\n%{http_code}" "$try_url" 2>/dev/null || true)
                  local http_code="${change_raw##*$'\n'}"
                  change_raw="${change_raw%$'\n'*}"
                  if [[ "$http_code" == "200" && -n "$change_raw" ]]; then
                    break
                  fi
                  change_raw=""
                fi
              done
              echo "DEBUG change_raw length=${#change_raw} for ${user}/${repo}" >&2
            fi

            # Drop -static- SPKs when a non-static equivalent exists.
            # Strategy: for each -static- URL, derive the expected non-static
            # URL by removing "-static" from the filename, and check if that
            # URL is present in the list. If yes, skip the static one.
            local filtered_spk_urls=()
            for u in "${all_spk_urls[@]}"; do
              local basename_u
              basename_u=$(basename "$u")
              if [[ "$basename_u" == *-static-* ]]; then
                local non_static_basename="${basename_u/-static-/-}"
                local found=0
                for v in "${all_spk_urls[@]}"; do
                  if [[ "$(basename "$v")" == "$non_static_basename" ]]; then
                    found=1
                    break
                  fi
                done
                if [[ "$found" -eq 1 ]]; then
                  echo "INFO: Dropping -static- SPK (non-static counterpart exists): ${basename_u}" >&2
                  continue
                fi
              fi
              filtered_spk_urls+=( "$u" )
            done
            all_spk_urls=( "${filtered_spk_urls[@]}" )

            # seen_noarch_ranges tracks firmware ranges already claimed by a
            # noarch SPK.  Key: pkg|version|os_min_ver|os_max_ver
            # Once set, any arch-specific SPK with the same key is skipped.
            declare -A seen_noarch_ranges

            # seen_arch_keys prevents duplicate entries for the same
            # pkg+version+arch+firmware range (safety net).
            # Key: pkg|version|arch|os_min_ver|os_max_ver
            declare -A seen_arch_keys

            # Track which package names have had their thumbnail processed this
            # run, so multi-SPK repos (e.g. Transcode DSM 7.2 + 7.3) only
            # attempt the thumbnail once per thumb_key.
            declare -A thumbnail_done

            local spk_url
            for spk_url in "${all_spk_urls[@]}"; do
              local info
              info=$(fetch_info_from_spk "${spk_url}")

              if [[ -z "$info" ]]; then
                echo "WARNING: Could not extract INFO from ${spk_url}" >&2
                continue
              fi

              # Read core fields from INFO
              local pkg arch exclude_arch os_min_ver os_max_ver
              pkg=$(        info_get "$info" "package")
              arch=$(       info_get "$info" "arch")
              exclude_arch=$(info_get "$info" "exclude_arch")
              os_min_ver=$( info_get "$info" "os_min_ver")
              os_max_ver=$( info_get "$info" "os_max_ver")

              # For noreleases repos, version comes from INFO rather than a release tag
              [[ -n "$noreleases" ]] && version=$(info_get "$info" "version")

              # Skip packages older than DSM 6
              local min_ver="${os_min_ver:-$(info_get "$info" "firmware")}"
              if [[ -n "$min_ver" && "${min_ver%%.*}" -lt 6 ]]; then
                echo "INFO: Skipping $(basename "${spk_url}") (os_min_ver=${min_ver} < 6)" >&2
                continue
              fi

              # Deduplication — see function header comment for rules.
              local spk_version
              spk_version=$(info_get "$info" "version")
              [[ -z "$spk_version" ]] && spk_version="${version}"
              local range_key="${pkg}|${spk_version}|${os_min_ver}|${os_max_ver}"
              local arch_key="${pkg}|${spk_version}|${arch}|${os_min_ver}|${os_max_ver}"

              if [[ "$arch" == "noarch" ]]; then
                # noarch claims this firmware range; mark it so arch-specifics skip it
                seen_noarch_ranges[$range_key]=1
              else
                # Skip if a noarch SPK already claimed this firmware range
                if [[ -n "${seen_noarch_ranges[$range_key]+x}" ]]; then
                  echo "INFO: Skipping ${arch} SPK (noarch covers ${os_min_ver}..${os_max_ver}): $(basename "${spk_url}")" >&2
                  continue
                fi
              fi

              echo "DEBUG arch_key='${arch_key}' seen=${seen_arch_keys[$arch_key]+set}" >&2

              # Skip exact duplicate (same pkg+version+arch+firmware range)
              if [[ -n "${seen_arch_keys[$arch_key]+x}" ]]; then
                echo "INFO: Skipping duplicate ${arch} SPK: $(basename "${spk_url}")" >&2
                continue
              fi
              seen_arch_keys[$arch_key]=1

              # beta: GitHub pre-release flag is authoritative.
              # If GitHub marks it as a pre-release, beta=true regardless of INFO.
              # If it's a full release, fall back to the INFO beta= field.
              # Normalise any non-standard INFO values (1, yes, True, etc).
              local is_prerelease
              is_prerelease=$(jq -r --arg url "${spk_url}" \
                'map(select(any(.assets[]; .browser_download_url == $url))) | .[0].prerelease // false' \
                <<< "$releases_to_process" | head -1)

              local beta
              beta=$(info_get "$info" "beta")

              echo "DEBUG beta from INFO='${beta}' for $(basename "${spk_url}")" >&2

              echo "DEBUG is_prerelease='${is_prerelease}' for ${spk_url}" >&2

              if [[ "${is_prerelease}" == "true" ]]; then
                beta="true"
              elif [[ -z "$beta" ]]; then
                beta="false"
              fi
              case "${beta,,}" in
                true|1|yes) beta="true" ;;
                *)          beta="false" ;;
              esac

              # Derive a unique thumbnail key per DSM version.
              # Packages with an os_max_ver (e.g. DSM6) get a _DSM<major> suffix
              # so they get their own thumbnail file and URL distinct from DSM7+.
              local thumb_key="${pkg}"
              if [[ -n "$os_max_ver" && "$os_max_ver" != "9.9-99999" ]]; then
                local dsm_major="${os_max_ver%%.*}"
                thumb_key="${pkg}_DSM${dsm_major}"
              fi

              # Append -beta suffix for pre-release packages so they get a distinct
              # thumbnail with a BETA overlay rather than sharing the stable thumbnail.
              if [[ "${is_prerelease}" == "true" ]]; then
                thumb_key="${thumb_key}-beta"
              fi

              # Update thumbnail once per thumb_key, only if version changed
              if [[ -z "${thumbnail_done[$thumb_key]+x}" ]]; then
                maybe_update_thumbnail "${spk_url}" "${pkg}" "${version}" "${thumb_key}" "${user}" "${repo}" "${is_prerelease}"
                thumbnail_done[$thumb_key]=1
              fi

              # ---- Changelog extraction ------------------------------------------------
              local changelog_json='{}'
              if [[ -n "$changelog_spec" ]]; then
                local spk_change_raw="$change_raw"
                echo "DEBUG spk_change_raw assigned length=${#spk_change_raw} changelog_spec='${changelog_spec}'" >&2
                echo "DEBUG spk_change_raw assigned length=${#spk_change_raw} changelog_spec='${changelog_spec}'" >&2

                # For DSM-split specs ("6:PKG_DSM6/CHANGELOG 7:PKG_DSM7/CHANGELOG"),
                # pick the path matching this SPK's DSM major version.
                if [[ "$changelog_spec" == *:* ]]; then
                  local dsm_major="${os_min_ver%%.*}"
                  local matched_path=""
                  for entry in $changelog_spec; do
                    local prefix="${entry%%:*}"
                    local path="${entry##*:}"
                    if [[ "$prefix" == "$dsm_major" ]]; then
                      matched_path="$path"
                      break
                    fi
                  done

                  # For beta SPKs try CHANGELOG_CURRENT_BETA first, fall back to CHANGELOG
                  local paths_to_try=()
                  if [[ "${is_prerelease}" == "true" && -n "$matched_path" ]]; then
                    paths_to_try+=( "${matched_path}_CURRENT_BETA" "$matched_path" )
                  elif [[ -n "$matched_path" ]]; then
                    paths_to_try+=( "$matched_path" )
                  fi

                  spk_change_raw=""
                  for path in "${paths_to_try[@]}"; do
                    for branch in main master; do
                      local try_url="https://raw.githubusercontent.com/${user}/${repo}/${branch}/${path}"
                      local raw
                      raw=$(curl -sSL --max-time 10 -w "\n%{http_code}" "$try_url" 2>/dev/null || true)
                      local http_code="${raw##*$'\n'}"
                      raw="${raw%$'\n'*}"
                      if [[ "$http_code" == "200" && -n "$raw" ]]; then
                        spk_change_raw="$raw"
                        break 2
                      fi
                    done
                  done
                fi

                # For version matching, also prepare a date-stripped fallback version
                local match_version="${spk_version}"
                local match_version_short=""
                if [[ "$match_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-[0-9]{8}$ ]]; then
                  match_version_short="${BASH_REMATCH[1]}"
                fi

                echo "DEBUG spk_change_raw length=${#spk_change_raw} for ${user}/${repo}" >&2

                # Call the Anthropic API to extract changelog for this version + all languages
                if [[ -n "$spk_change_raw" ]]; then
                  local prompt
                  prompt="Extract the changelog entries for version ${match_version} from this changelog file.
              If version ${match_version} is not found, try matching ${match_version_short:-${match_version}} instead (ignoring any date suffix).
              Return ONLY a raw JSON object with no markdown formatting, no code fences, no backticks.
              Map DSM language codes to numbered lists, using these codes: enu, ger, fre, ita, spn, jpn, cht, chs, krn, dan, nor, sve, nld, rus, plk, ptb, hun, trk, csy.
              Only include languages actually present in the changelog. Always include enu (use English entries, or translate from the only language present if English is absent).
              Format each value as a plain numbered list: \"1. First item.\n2. Second item.\"
              No markdown, no preamble, no version header, no language label. If the version is not found return {}.
              Example output: {\"enu\":\"1. Fixed login bug.\n2. Improved performance.\",\"ger\":\"1. Login-Fehler behoben.\n2. Leistung verbessert.\"}

              Changelog:
              ${spk_change_raw}"
              # ^^^ closing quote of prompt string is above

                  local api_response=""
                  local _delay=15
                  for _retry in 1 2 3; do
                    api_response=$(curl -s https://api.anthropic.com/v1/messages \
                      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
                      -H "anthropic-version: 2023-06-01" \
                      -H "content-type: application/json" \
                      -d "$(jq -n --arg prompt "$prompt" '{
                        model: "claude-haiku-4-5-20251001",
                        max_tokens: 512,
                        messages: [{ role: "user", content: $prompt }]
                      }')" 2>/dev/null || true)
                    # Break if not an overload error
                    if ! echo "$api_response" | jq -e '.error.type == "overloaded_error"' >/dev/null 2>&1; then
                      break
                    fi
                    echo "WARNING: API overloaded, retrying in ${_delay}s (attempt ${_retry}/3)..." >&2
                    sleep "${_delay}"
                    _delay=$(( _delay * 2 ))
                  done

                  echo "DEBUG api_response=${api_response}" >&2

                  # Strip markdown code fences if present
                  lang_map=$(echo "$api_response" \
                    | jq -r '.content[0].text // ""' 2>/dev/null \
                    | sed '/^```/d' \
                    || true)

                  echo "DEBUG lang_map='${lang_map}'" >&2

                  if echo "$lang_map" | jq -e 'type == "object"' >/dev/null 2>&1; then
                    changelog_json=$(echo "$lang_map" | jq -c '
                      to_entries |
                      map(if .key == "enu"
                        then { key: "changelog", value: .value }
                        else { key: ("changelog_" + .key), value: .value }
                        end) |
                      from_entries')
                  else
                    echo "WARNING: Unexpected changelog API response for ${user}/${repo} ${spk_version}" >&2
                    changelog_json='{}'
                  fi
                fi
              fi
              # ---- End changelog extraction --------------------------------------------

              # Fall back to existing changelog from previous index.json if API failed
              if [[ "$changelog_json" == '{}' && -f "${REPO_DIR}/index.json" ]]; then
                local existing_cl
                existing_cl=$(jq -rc --arg pkg "$pkg" '
                  first(
                    .packages[] | select(.package == $pkg and (.changelog // "") != "") |
                    { changelog: .changelog } +
                    (to_entries | map(select(.key | startswith("changelog_"))) | from_entries)
                  ) // {}
                ' "${REPO_DIR}/index.json" 2>/dev/null || echo '{}')
                [[ "$existing_cl" != '{}' ]] && changelog_json="$existing_cl"
              fi

              # Read remaining metadata from INFO — all fields verbatim, no substitution
              local dname desc maintainer maintainer_url distributor distributor_url support_url
              dname=$(           info_get "$info" "displayname")
              [[ -z "$dname" ]]  && dname="$pkg"
              desc=$(            info_get "$info" "description")
              maintainer=$(      info_get "$info" "maintainer")
              maintainer_url=$(  info_get "$info" "maintainer_url")
              distributor=$(     info_get "$info" "distributor")
              distributor_url=$( info_get "$info" "distributor_url")
              support_url=$(     info_get "$info" "support_url")

              # Collect localised displayname_<lang> fields from INFO
              local dname_langs
              dname_langs=$(echo "$info" | grep -E '^displayname_[a-z]+=' | \
                sed 's/^displayname_\([a-z]*\)=\(.*\)$/\1 \2/' | \
                while IFS=' ' read -r lang val; do
                  val="${val#\"}" ; val="${val%\"}"
                  val="${val#\'}" ; val="${val%\'}"
                  printf '"%s":"%s"\n' "dname_${lang}" "$val"
                done | paste -sd ',' | sed 's/^/{/;s/$/}/')
              [[ -z "$dname_langs" || "$dname_langs" == "{}" ]] && dname_langs="{}"

              # Collect localised description_<lang> fields from INFO
              local desc_langs
              desc_langs=$(echo "$info" | grep -E '^description_[a-z]+=' | \
                sed 's/^description_\([a-z]*\)=\(.*\)$/\1 \2/' | \
                while IFS=' ' read -r lang val; do
                  val="${val#\"}" ; val="${val%\"}"
                  val="${val#\'}" ; val="${val%\'}"
                  printf '"%s":"%s"\n' "desc_${lang}" "$val"
                done | paste -sd ',' | sed 's/^/{/;s/$/}/')
              [[ -z "$desc_langs" || "$desc_langs" == "{}" ]] && desc_langs="{}"

              # Firmware: prefer os_min_ver; fall back to the INFO firmware= key
              # (DSM6 packages use firmware= instead of os_min_ver=); last
              # resort is a safe default.
              local firmware="${os_min_ver}"
              [[ -z "$firmware" ]] && firmware=$(info_get "$info" "firmware")
              [[ -z "$firmware" ]] && firmware="7.0-0000"

              # os_max_ver: treat "9.9-99999" or absent as no upper bound
              local max_ver_json="null"
              if [[ -n "$os_max_ver" && "$os_max_ver" != "9.9-99999" ]]; then
                max_ver_json="\"${os_max_ver}\""
              fi

              local size=0
              if [[ -z "$noreleases" ]]; then
                size=$(jq -r --arg url "${spk_url}" \
                  '.[].assets[] | select(.browser_download_url == $url) | .size' \
                  <<< "$releases_to_process" | head -1)
                size="${size:-0}"
              fi

              local thumbnail="https://007revad.github.io/${REPO_DIR}/thumbnails/${thumb_key}_120.png"

              echo "DEBUG changelog_json='${changelog_json}'" >&2

              local changelog_enu=""
              local changelog_extra="{}"
              if printf '%s' "${changelog_json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
                changelog_enu=$(printf '%s' "${changelog_json}" | jq -r '.changelog // ""')
                changelog_extra=$(printf '%s' "${changelog_json}" | jq -c 'del(.changelog)')
              fi

              jq -n \
                --arg package              "${pkg}" \
                --arg version              "${spk_version}" \
                --arg dname                "${dname}" \
                --argjson dname_langs      "${dname_langs}" \
                --arg desc                 "${desc}" \
                --argjson desc_langs       "${desc_langs}" \
                --arg maintainer           "${maintainer}" \
                --arg maintainer_url       "${maintainer_url}" \
                --arg distributor          "${distributor}" \
                --arg dist_url             "${distributor_url}" \
                --arg support_url          "${support_url}" \
                --arg report_url           "${support_url}" \
                --arg link                 "${spk_url}" \
                --arg arch                 "${arch}" \
                --arg exclude_arch         "${exclude_arch}" \
                --arg firmware             "${firmware}" \
                --argjson os_max_ver       "${max_ver_json}" \
                --arg thumbnail            "${thumbnail}" \
                --argjson beta             "${beta}" \
                --argjson size             "${size}" \
                --argjson download_count   "${download_count}" \
                --arg changelog            "${changelog_enu}" \
                --argjson changelog_extra  "${changelog_extra}" \
                '{
                  package:               $package,
                  version:               $version,
                  dname:                 $dname,
                  desc:                  $desc,
                  maintainer:            $maintainer,
                  maintainer_url:        $maintainer_url,
                  distributor:           $distributor,
                  distributor_url:       $dist_url,
                  support_url:           $support_url,
                  report_url:            $report_url,
                  link:                  $link,
                  arch:                  $arch,
                  exclude_arch:          (if $exclude_arch == "" then null else $exclude_arch end),
                  firmware:              $firmware,
                  os_max_ver:            $os_max_ver,
                  thumbnail:             [$thumbnail],
                  snapshot:              [],
                  beta:                  $beta,
                  size:                  $size,
                  download_count:        $download_count,
                  recent_download_count: $download_count
                } + $dname_langs + $desc_langs + $changelog_extra + {changelog: $changelog}'
            done
          }

          # ------------------------------------------------------------------ #
          # Build each package entry.
          # To add a new package, append one make_entries line here.
          # ------------------------------------------------------------------ #
          entries=()

          # 007revad repos
          entries+=( "$(make_entries "007revad" "Synology_Ookla_Speedtest"     "CHANGES.txt")" )
          entries+=( "$(make_entries "007revad" "Synology_Open_Speedtest"      "CHANGES.txt")" )
          entries+=( "$(make_entries "007revad" "Synology_Libre_Speedtest"     "CHANGES.txt")" )
          entries+=( "$(make_entries "007revad" "Transcode_for_x25"            "CHANGES.txt")" )
          entries+=( "$(make_entries "007revad" "DSM_Notify"                   "CHANGES.txt")" )

          # Friends' repos
          entries+=( "$(make_entries "PeterSuh-Q3" "SynoSmartInfo"             "")" )
          entries+=( "$(make_entries "toafez"      "AutoPilot"                 "CHANGELOG")" )
          entries+=( "$(make_entries "toafez"      "LogAnalysis"               "CHANGELOG")" )
          entries+=( "$(make_entries "schmidhorst" "synology-autorun"          "CHANGELOG")" )
          entries+=( "$(make_entries "geimist"     "synOCR"                    "6:PKG_DSM6/CHANGELOG 7:PKG_DSM7/CHANGELOG")" )

          #entries+=( "$(make_entries "bb-qq"          "aqc111"                "")" )
          #entries+=( "$(make_entries "bb-qq"          "r8152"                 "")" )
          #entries+=( "$(make_entries "bb-qq"          "uas"                   "")" )
          entries+=( "$(make_entries "eizedev"         "AirConnect-Synology"   "")" )
          #entries+=( "$(make_entries "efren-builder"  "synology-uptime-kuma   "CHANGELOG.md")" )  # Newer version on synocommunity

          # Company's repos
          entries+=( "$(make_entries "homebridge"  "homebridge-syno-spk"       "changelog.md")" )

          # repos with spk files in repo file tree
          entries+=( "$(make_entries "BenjV" "SYNO-packages" ""                "noreleases")" )

          # ------------------------------------------------------------------ #
          # Combine into final index.json
          # ------------------------------------------------------------------ #
          printf '%s\n' "${entries[@]}" | jq -s '{"packages": .}' > ${REPO_DIR}/index.json

          echo "Generated ${REPO_DIR}/index.json:"
          cat ${REPO_DIR}/index.json
