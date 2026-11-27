import base64
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from sparkle_release import (
    SPARKLE_NAMESPACE,
    validate_appcast,
    validate_ipa_metadata,
    validate_public_key,
    validate_stable_release,
)


class SparkleReleaseValidationTests(unittest.TestCase):
    def test_accepts_exact_stable_tag_bundle_and_monotonic_build(self):
        validate_stable_release(
            tag="v1.2.3",
            version="1.2.3",
            build_number="42",
            bundle_version="1.2.3",
            bundle_build="42",
            archive_name="Daybreak-1.2.3-macOS.zip",
        )

    def test_rejects_non_semver_and_leading_zero_components(self):
        for version in ("1.2", "01.2.3", "1.2.3.4", "1.2.3/evil"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_stable_release(
                    tag=f"v{version}",
                    version=version,
                    build_number="42",
                    bundle_version=version,
                    bundle_build="42",
                    archive_name=f"Daybreak-{version}-macOS.zip",
                )

    def test_rejects_prerelease_and_build_metadata_from_stable_feed(self):
        for version in ("1.2.3-rc.1", "1.2.3+build.7"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_stable_release(
                    tag=f"v{version}",
                    version=version,
                    build_number="42",
                    bundle_version=version,
                    bundle_build="42",
                    archive_name=f"Daybreak-{version}-macOS.zip",
                )

    def test_rejects_mismatched_tag_bundle_build_and_asset(self):
        valid = {
            "tag": "v1.2.3",
            "version": "1.2.3",
            "build_number": "42",
            "bundle_version": "1.2.3",
            "bundle_build": "42",
            "archive_name": "Daybreak-1.2.3-macOS.zip",
        }
        for change in (
            {"tag": "v1.2.4"},
            {"bundle_version": "1.2.2"},
            {"bundle_build": "41"},
            {"archive_name": "Daybreak-1.2.3.zip"},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_stable_release(**(valid | change))

    def test_build_number_must_be_a_positive_canonical_integer(self):
        for build_number in ("", "0", "042", "-1", "4.2"):
            with self.subTest(build_number=build_number), self.assertRaises(ValueError):
                validate_stable_release(
                    tag="v1.2.3",
                    version="1.2.3",
                    build_number=build_number,
                    bundle_version="1.2.3",
                    bundle_build=build_number,
                    archive_name="Daybreak-1.2.3-macOS.zip",
                )

    def test_validates_version_and_build_in_packaged_ipa(self):
        info_plist = {
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "Daybreak.ipa"

            def write_ipa(metadata):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(
                        "Payload/Daybreak.app/Info.plist",
                        plistlib.dumps(metadata),
                    )

            write_ipa(info_plist)
            validate_ipa_metadata(path=path, version="1.2.3", build_number="42")

            for key, value in (
                ("CFBundleShortVersionString", "1.2.2"),
                ("CFBundleVersion", "41"),
            ):
                with self.subTest(key=key):
                    write_ipa(info_plist | {key: value})
                    with self.assertRaises(ValueError):
                        validate_ipa_metadata(
                            path=path,
                            version="1.2.3",
                            build_number="42",
                        )

    def test_rejects_ipa_without_daybreak_info_plist(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "Daybreak.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(
                    "Payload/Other.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleShortVersionString": "1.2.3",
                            "CFBundleVersion": "42",
                        }
                    ),
                )

            with self.assertRaisesRegex(ValueError, "Daybreak Info.plist"):
                validate_ipa_metadata(
                    path=path,
                    version="1.2.3",
                    build_number="42",
                )

    def test_requires_well_formed_eddsa_public_key(self):
        public_key = base64.b64encode(bytes(range(32))).decode("ascii")
        validate_public_key(public_key)
        for invalid in ("", "not-base64", base64.b64encode(bytes(31)).decode("ascii")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                validate_public_key(invalid)

    def test_validates_signed_appcast_version_build_asset_and_release_notes(self):
        sparkle = f"{{{SPARKLE_NAMESPACE}}}"
        rss = ET.Element("rss")
        channel = ET.SubElement(rss, "channel")
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, f"{sparkle}version").text = "42"
        ET.SubElement(item, f"{sparkle}shortVersionString").text = "1.2.3"
        ET.SubElement(item, f"{sparkle}fullReleaseNotesLink").text = (
            "https://github.com/mentalfl0w/Daybreak/releases/tag/v1.2.3"
        )
        ET.SubElement(
            item,
            "enclosure",
            {
                "url": "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.3/Daybreak-1.2.3-macOS.zip",
                "length": "512",
                f"{sparkle}edSignature": "offline-signature",
            },
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "appcast.xml"
            ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
            validate_appcast(
                path=path,
                tag="v1.2.3",
                version="1.2.3",
                build_number="42",
                archive_name="Daybreak-1.2.3-macOS.zip",
            )

    def test_rejects_unverified_appcast_metadata(self):
        sparkle = f"{{{SPARKLE_NAMESPACE}}}"
        rss = ET.Element("rss")
        channel = ET.SubElement(rss, "channel")
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, f"{sparkle}version").text = "41"
        ET.SubElement(item, f"{sparkle}shortVersionString").text = "1.2.3"
        ET.SubElement(item, f"{sparkle}fullReleaseNotesLink").text = (
            "https://github.com/mentalfl0w/Daybreak/releases/tag/v1.2.3"
        )
        ET.SubElement(
            item,
            "enclosure",
            {
                "url": "https://github.com/mentalfl0w/Daybreak/releases/download/v1.2.3/Daybreak-1.2.3-macOS.zip",
                "length": "512",
            },
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "appcast.xml"
            ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
            with self.assertRaises(ValueError):
                validate_appcast(
                    path=path,
                    tag="v1.2.3",
                    version="1.2.3",
                    build_number="42",
                    archive_name="Daybreak-1.2.3-macOS.zip",
                )


if __name__ == "__main__":
    unittest.main()
