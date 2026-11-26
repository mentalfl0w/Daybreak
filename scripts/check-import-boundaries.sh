#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

violations=0

report_violation() {
  printf 'ERROR: %s\n' "$1" >&2
  violations=$((violations + 1))
}

check_swift_imports() {
  local search_root="$1"
  local forbidden_modules="$2"
  local rule="$3"
  local import_pattern file matches match grep_status

  if [[ ! -d "$search_root" ]]; then
    report_violation "missing source directory: $search_root ($rule)"
    return
  fi

  import_pattern="^[[:space:]]*((@[[:alnum:]_]+([[:space:]]*\\([^)]*\\))?|public|package|private|fileprivate)[[:space:]]+)*import[[:space:]]+(${forbidden_modules})([.]|[[:space:]]|$)"
  while IFS= read -r -d '' file; do
    if matches="$(grep -nE "$import_pattern" "$file")"; then
      while IFS= read -r match; do
        report_violation "$file:${match%%:*}: forbidden import under $rule: ${match#*:}"
      done <<< "$matches"
    else
      grep_status=$?
      if (( grep_status != 1 )); then
        report_violation "could not scan $file (grep exited $grep_status)"
      fi
    fi
  done < <(
    find "$search_root" \
      -type d \( \
        -name .git -o \
        -name .build -o \
        -name build -o \
        -name Build -o \
        -name DerivedData -o \
        -iname '*generated*' -o \
        -name SourcePackages -o \
        -name xcuserdata \
      \) -prune -o \
      -type f -name '*.swift' -print0
  )
}

project_section_has() {
  local project_file="$1"
  local section="$2"
  local needle="$3"

  awk -v section="$section" -v needle="$needle" '
    $0 == "  " section ":" { in_section = 1; next }
    in_section && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_section && index($0, needle) { found = 1 }
    END { exit !found }
  ' "$project_file"
}

project_package_path_is() {
  local project_file="$1"
  local package_name="$2"
  local expected_path="$3"

  awk -v package_name="$package_name" -v expected_path="$expected_path" '
    $0 == "packages:" { in_packages = 1; next }
    in_packages && $0 == "targets:" { in_packages = 0 }
    in_packages && $0 == "  " package_name ":" { in_package = 1; next }
    in_package && /^  [[:alnum:]_-]+:[[:space:]]*$/ { in_package = 0 }
    in_package && /^[[:space:]]+path:[[:space:]]*/ {
      path = $0
      sub(/^[[:space:]]*path:[[:space:]]*/, "", path)
      gsub(/"/, "", path)
      found = path == expected_path
    }
    END { exit !found }
  ' "$project_file"
}

check_swift_imports \
  "Packages/DaybreakCore/Sources" \
  'AppKit|SwiftUI|UIKit|MacIntegration|MobileApp|Apps[.]MobileApp' \
  'DaybreakCore must remain platform-independent'
check_swift_imports \
  "Platform/MacIntegration" \
  'MobileApp|Apps[.]MobileApp' \
  'MacIntegration must not depend on the mobile app'
check_swift_imports \
  "Apps/MobileApp" \
  'MacIntegration' \
  'MobileApp must not depend on the macOS integration'

core_manifest="Packages/DaybreakCore/Package.swift"
integration_manifest="Platform/MacIntegration/Package.swift"
project_spec="Apps/MacApp/project.yml"

for required_file in "$core_manifest" "$integration_manifest" "$project_spec"; do
  if [[ ! -f "$required_file" ]]; then
    report_violation "missing dependency configuration: $required_file"
  fi
done

if [[ -f "$core_manifest" ]]; then
  if matches="$(grep -nE '\.package[[:space:]]*\(' "$core_manifest")"; then
    while IFS= read -r match; do
      report_violation "$core_manifest:${match%%:*}: DaybreakCore must not declare package dependencies: ${match#*:}"
    done <<< "$matches"
  else
    grep_status=$?
    if (( grep_status != 1 )); then
      report_violation "could not scan $core_manifest (grep exited $grep_status)"
    fi
  fi
fi

if [[ -f "$integration_manifest" ]]; then
  if ! grep -Eq '^[[:space:]]*\.package[[:space:]]*\([[:space:]]*path:[[:space:]]*"\.\./\.\./Packages/DaybreakCore"[[:space:]]*\)' "$integration_manifest"; then
    report_violation "$integration_manifest must declare the local DaybreakCore package dependency"
  fi
  if ! grep -Eq '\.product[[:space:]]*\([[:space:]]*name:[[:space:]]*"DaybreakCore"[[:space:]]*,[[:space:]]*package:[[:space:]]*"DaybreakCore"' "$integration_manifest"; then
    report_violation "$integration_manifest must link its target to the DaybreakCore product"
  fi

  if matches="$(grep -nE 'path:[[:space:]]*"' "$integration_manifest")"; then
    while IFS= read -r match; do
      if [[ "$match" != *'path: "../../Packages/DaybreakCore"'* ]]; then
        report_violation "$integration_manifest:${match%%:*}: local package dependencies must point to DaybreakCore: ${match#*:}"
      fi
    done <<< "$matches"
  else
    grep_status=$?
    if (( grep_status != 1 )); then
      report_violation "could not scan $integration_manifest (grep exited $grep_status)"
    fi
  fi
fi

if [[ -f "$project_spec" ]]; then
  if ! project_package_path_is "$project_spec" DaybreakCore Packages/DaybreakCore; then
    report_violation "$project_spec must map DaybreakCore to Packages/DaybreakCore"
  fi
  if ! project_package_path_is "$project_spec" MacIntegration Platform/MacIntegration; then
    report_violation "$project_spec must map MacIntegration to Platform/MacIntegration"
  fi
  if ! project_section_has "$project_spec" Daybreak '- package: DaybreakCore'; then
    report_violation "$project_spec target Daybreak must depend on DaybreakCore"
  fi
  if ! project_section_has "$project_spec" Daybreak '- package: MacIntegration'; then
    report_violation "$project_spec target Daybreak must depend on MacIntegration"
  fi
  if ! project_section_has "$project_spec" DaybreakMobile '- package: DaybreakCore'; then
    report_violation "$project_spec target DaybreakMobile must depend on DaybreakCore"
  fi
  if project_section_has "$project_spec" DaybreakMobile '- package: MacIntegration'; then
    report_violation "$project_spec target DaybreakMobile must not depend on MacIntegration"
  fi
fi

if (( violations > 0 )); then
  printf 'Import-boundary check failed: %d violation(s).\n' "$violations" >&2
  exit 1
fi

printf 'Import-boundary check passed.\n'
