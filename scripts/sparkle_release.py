#!/usr/bin/env python3
"""Offline validation for Daybreak release metadata."""

from __future__ import annotations

import argparse
import base64
import binascii
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

CORE_VERSION = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = r"[0-9A-Za-z-]+"
PRERELEASE_IDENTIFIER = r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = re.compile(
    rf"{CORE_VERSION}\.{CORE_VERSION}\.{CORE_VERSION}"
    rf"(?:-{PRERELEASE_IDENTIFIER}(?:\.{PRERELEASE_IDENTIFIER})*)?"
    rf"(?:\+{IDENTIFIER}(?:\.{IDENTIFIER})*)?\Z"
)
STABLE_VERSION = re.compile(rf"{CORE_VERSION}\.{CORE_VERSION}\.{CORE_VERSION}\Z")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_URL_PREFIX = "https://github.com/mentalfl0w/Daybreak/releases/download/"
RELEASE_NOTES_URL_PREFIX = "https://github.com/mentalfl0w/Daybreak/releases/tag/"


def validate_semver(version: str) -> None:
    if not SEMVER.fullmatch(version):
        raise ValueError("version must be strict Semantic Versioning")


def is_stable_version(version: str) -> bool:
    return STABLE_VERSION.fullmatch(version) is not None


def validate_stable_release(
    *,
    tag: str,
    version: str,
    build_number: str,
    bundle_version: str,
    bundle_build: str,
    archive_name: str,
    prerelease: bool = False,
) -> None:
    validate_semver(version)
    if prerelease or not is_stable_version(version):
        raise ValueError("Sparkle feeds are published only for stable releases")
    if tag != f"v{version}":
        raise ValueError("release tag must be exactly v<bundle version>")
    if bundle_version != version:
        raise ValueError("CFBundleShortVersionString does not match the release tag")
    if not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ValueError("build number must be a positive, canonical GitHub run number")
    if bundle_build != build_number:
        raise ValueError("CFBundleVersion does not match the monotonic GitHub run number")
    if archive_name != f"Daybreak-{version}-macOS.zip":
        raise ValueError("Sparkle archive name does not match the stable release version")



def validate_ipa_metadata(*, path: Path, version: str, build_number: str) -> None:
    try:
        with zipfile.ZipFile(path) as archive:
            info_plist = plistlib.loads(
                archive.read("Payload/Daybreak.app/Info.plist")
            )
    except (
        OSError,
        KeyError,
        zipfile.BadZipFile,
        plistlib.InvalidFileException,
        ValueError,
    ) as error:
        raise ValueError(
            "iOS IPA does not contain a readable Daybreak Info.plist"
        ) from error

    if not isinstance(info_plist, dict):
        raise ValueError("iOS IPA Daybreak Info.plist is not a dictionary")
    if info_plist.get("CFBundleShortVersionString") != version:
        raise ValueError(
            "iOS IPA CFBundleShortVersionString does not match the release tag"
        )
    if info_plist.get("CFBundleVersion") != build_number:
        raise ValueError(
            "iOS IPA CFBundleVersion does not match the release build number"
        )


def validate_public_key(public_key: str) -> None:
    if not public_key or public_key != public_key.strip():
        raise ValueError("Sparkle public key is missing or has surrounding whitespace")
    try:
        key_bytes = base64.b64decode(public_key, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("Sparkle public key is not valid base64") from error
    if len(key_bytes) != 32:
        raise ValueError("Sparkle EdDSA public key must encode exactly 32 bytes")


def validate_appcast(
    *,
    path: Path,
    tag: str,
    version: str,
    build_number: str,
    archive_name: str,
) -> None:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as error:
        raise ValueError("generated Sparkle appcast is unreadable") from error

    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("stable Sparkle appcast must contain exactly one release item")

    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Sparkle appcast item has no enclosure")

    expected_url = f"{FEED_URL_PREFIX}{tag}/{archive_name}"
    if enclosure.get("url") != expected_url:
        raise ValueError("Sparkle enclosure URL does not match the published archive")
    if not enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature"):
        raise ValueError("Sparkle archive signature is missing")
    if enclosure.get("length", "0").isdecimal() is False or int(enclosure.get("length", "0")) < 1:
        raise ValueError("Sparkle archive length is missing or invalid")

    sparkle_version = item.find(f"{{{SPARKLE_NAMESPACE}}}version")
    short_version = item.find(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
    if sparkle_version is None or sparkle_version.text != build_number:
        raise ValueError("Sparkle appcast build version does not match CFBundleVersion")
    if short_version is None or short_version.text != version:
        raise ValueError("Sparkle appcast short version does not match the release tag")

    release_notes_link = item.find(f"{{{SPARKLE_NAMESPACE}}}fullReleaseNotesLink")
    if release_notes_link is None or release_notes_link.text != f"{RELEASE_NOTES_URL_PREFIX}{tag}":
        raise ValueError("Sparkle release notes link does not match the GitHub release")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    version = commands.add_parser("validate-version")
    version.add_argument("--version", required=True)

    metadata = commands.add_parser("validate-release")
    metadata.add_argument("--tag", required=True)
    metadata.add_argument("--version", required=True)
    metadata.add_argument("--build-number", required=True)
    metadata.add_argument("--bundle-version", required=True)
    metadata.add_argument("--bundle-build", required=True)
    metadata.add_argument("--archive-name", required=True)

    ipa = commands.add_parser("validate-ipa")
    ipa.add_argument("--path", required=True, type=Path)
    ipa.add_argument("--version", required=True)
    ipa.add_argument("--build-number", required=True)

    public_key = commands.add_parser("validate-public-key")
    public_key.add_argument("--public-key", required=True)

    appcast = commands.add_parser("validate-appcast")
    appcast.add_argument("--path", required=True, type=Path)
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--build-number", required=True)
    appcast.add_argument("--archive-name", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "validate-version":
            validate_semver(args.version)
        elif args.command == "validate-release":
            validate_stable_release(
                tag=args.tag,
                version=args.version,
                build_number=args.build_number,
                bundle_version=args.bundle_version,
                bundle_build=args.bundle_build,
                archive_name=args.archive_name,
            )
        elif args.command == "validate-ipa":
            validate_ipa_metadata(
                path=args.path,
                version=args.version,
                build_number=args.build_number,
            )
        elif args.command == "validate-public-key":
            validate_public_key(args.public_key)
        else:
            validate_appcast(
                path=args.path,
                tag=args.tag,
                version=args.version,
                build_number=args.build_number,
                archive_name=args.archive_name,
            )
    except ValueError as error:
        print(f"Sparkle release validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
