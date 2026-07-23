#!/usr/bin/env python3
"""
Converts an .xcresult bundle produced by `xcodebuild test -resultBundlePath`
into a JUnit XML report, using `xcrun xcresulttool get test-results tests`
(the structured test-results JSON API Apple introduced in Xcode 16 to
properly represent both XCTest and Swift Testing results in one format).

WHY THIS EXISTS: `xcpretty --report junit` parses xcodebuild's TEXT
console output, and xcpretty was built years before Swift Testing existed
— it does not recognize Swift Testing's console output format. That
mismatch is the most likely explanation for a build that completes
successfully while its JUnit report shows `tests="0"`: xcpretty simply
never recognized any test lines to report on, even though xcodebuild
itself ran them. This script reads the actual structured result data
instead of scraping console text, so it can't have that failure mode.

HONESTY NOTE (do not remove): the exact JSON field names below reflect
the Xcode 16 `xcresulttool get test-results` schema as documented at the
time this script was written. They have NOT been verified against your
specific Xcode version (26.4.1) in a real run, because no Xcode/macOS
runtime was available while writing this. If this script's parsing step
fails, run the command below manually and share the raw JSON output —
that's the fastest way to correct the field names precisely rather than
guessing again:

    xcrun xcresulttool get test-results tests --path <path>.xcresult --format json

CRITICAL BEHAVIOR: on any failure to parse a real result — missing file,
unexpected JSON shape, zero test nodes found — this script EXITS
NON-ZERO and does not write a JUnit file at all. It never writes a
"tests=0" placeholder as if that were a valid, passing report. The
caller (codemagic.yaml) is responsible for treating a missing/absent
JUnit file, or an explicit non-zero exit here, as a hard build failure.
"""

import argparse
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def run_xcresulttool(xcresult_path: Path) -> dict:
    cmd = [
        "xcrun", "xcresulttool", "get", "test-results", "tests",
        "--path", str(xcresult_path),
        "--format", "json",
    ]
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        fail(
            "xcresulttool failed (exit "
            f"{result.returncode}). stderr:\n{result.stderr}\n"
            "This usually means either the .xcresult bundle doesn't exist "
            "(tests never ran) or this Xcode version's xcresulttool JSON "
            "schema differs from what this script expects. Re-run the "
            "xcrun command above manually and share the output."
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        fail(f"Could not parse xcresulttool output as JSON: {e}\nRaw output:\n{result.stdout[:2000]}")


def collect_test_cases(node: dict, out: list) -> None:
    """Recursively walk the test-results node tree collecting leaf test cases.

    Expected shape (Xcode 16+ `test-results tests` JSON): a tree of nodes
    with `nodeType` in {"Test Plan", "Unit test bundle", "Test Suite",
    "Test Case", ...} and children in `children`. Leaf nodes with
    nodeType == "Test Case" carry a `result` field (e.g. "Passed",
    "Failed", "Skipped", "Expected Failure").
    """
    node_type = node.get("nodeType", "")
    if node_type == "Test Case":
        out.append(node)
        return
    for child in node.get("children", []):
        collect_test_cases(child, out)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", required=True, type=Path)
    parser.add_argument("--junit-output", required=True, type=Path)
    args = parser.parse_args()

    if not args.xcresult.exists():
        fail(
            f"{args.xcresult} does not exist. This means `xcodebuild test "
            "-resultBundlePath ...` did not produce a result bundle at "
            "all — the build/test invocation itself failed before "
            "producing results. Do not treat this as zero tests; treat "
            "it as the test run never happening."
        )

    data = run_xcresulttool(args.xcresult)

    test_cases: list = []
    # Top-level shape may be a single root node, or {"testNodes": [...]}
    if "testNodes" in data:
        for root_node in data["testNodes"]:
            collect_test_cases(root_node, test_cases)
    else:
        collect_test_cases(data, test_cases)

    if not test_cases:
        fail(
            "Parsed the .xcresult successfully but found ZERO test case "
            "nodes in it. This means either no tests were actually "
            "discovered/run by xcodebuild, or this script's understanding "
            "of the JSON shape doesn't match your Xcode version's output. "
            "Either way, this must fail the build, not report success."
        )

    passed = sum(1 for t in test_cases if t.get("result") in ("Passed", "Expected Failure"))
    failed = sum(1 for t in test_cases if t.get("result") == "Failed")
    skipped = sum(1 for t in test_cases if t.get("result") == "Skipped")

    print(f"Discovered {len(test_cases)} test case(s): {passed} passed, {failed} failed, {skipped} skipped.")

    testsuites = ET.Element("testsuites", {
        "tests": str(len(test_cases)),
        "failures": str(failed),
        "skipped": str(skipped),
    })
    testsuite = ET.SubElement(testsuites, "testsuite", {
        "name": "VoxtrSprint0Tests",
        "tests": str(len(test_cases)),
        "failures": str(failed),
        "skipped": str(skipped),
    })
    for t in test_cases:
        name = t.get("name", "unknown")
        classname = t.get("parentNodeName") or t.get("nodeIdentifier", "VoxtrSprint0Tests")
        testcase = ET.SubElement(testsuite, "testcase", {"name": name, "classname": str(classname)})
        result = t.get("result")
        if result == "Failed":
            failure_message = t.get("failureMessage", "Test failed")
            ET.SubElement(testcase, "failure", {"message": failure_message})
        elif result == "Skipped":
            ET.SubElement(testcase, "skipped")

    args.junit_output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(testsuites).write(args.junit_output, encoding="utf-8", xml_declaration=True)
    print(f"Wrote JUnit report to {args.junit_output} ({len(test_cases)} tests)")

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
