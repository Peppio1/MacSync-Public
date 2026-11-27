#!/usr/bin/env python3
"""Inject the same synthetic test into both pinned checkouts; never edit product source."""
import pathlib
import sys
root, suite = pathlib.Path(sys.argv[1]), sys.argv[2]
assets = pathlib.Path(__file__).resolve().parent
mapping = {
    "local": ("MirrorDeletionTests.swift", "final class MirrorDeletionTests: XCTestCase {", "local.swift.txt"),
    "smb": ("SMBV0192DeletionValidationTests.swift", "final class SMBV0192DeletionValidationTests:XCTestCase {", "smb.swift.txt"),
    "lifecycle": ("SMBV0192DeletionValidationTests.swift", "final class SMBV0192DeletionValidationTests:XCTestCase {", "lifecycle.swift.txt"),
}
file, anchor, fixture = mapping[suite]
target = root / "Tests/MacSyncCoreTests" / file
text = target.read_text()
assert text.count(anchor) == 1
body = (assets / fixture).read_text()
assert "MACSYNC_COMPARE_OBSERVED" in body
assert "func testComparative" in body
assert "func testComparative" not in text
target.write_text(text.replace(anchor, anchor + "\n" + body, 1))
