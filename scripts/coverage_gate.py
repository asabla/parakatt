"""Fail closed on missing coverage and protect critical persistence contracts."""

import argparse
import json
import pathlib

POLICY = pathlib.Path(__file__).with_name("coverage-policy.json")


def rust_lines(report, module):
    files = [
        item
        for unit in report.get("data", [])
        for item in unit.get("files", [])
        if item["filename"].replace("\\", "/").endswith("/" + module)
    ]
    if len(files) != 1:
        raise ValueError(f"Expected coverage for exactly one {module}")
    lines = files[0]["summary"]["lines"]
    covered, count = lines["covered"], lines["count"]
    if not 0 <= covered <= count or count == 0:
        raise ValueError(f"Invalid line counts for {module}")
    return covered, count


def check_rust(current, baseline, modules):
    for module in modules:
        covered, count = rust_lines(current, module)
        old_covered, old_count = rust_lines(baseline, module)
        print(f"{module}: {covered}/{count}; base {old_covered}/{old_count}")
        if covered * old_count < old_covered * count:
            raise ValueError(f"Line coverage decreased in {module}")


def check_swift(report, functions):
    found = {}
    for target in report.get("targets", []):
        if target.get("name") != "ParakattApp.framework":
            continue
        for file in target.get("files", []):
            for function in file.get("functions", []):
                if function["name"] in functions:
                    if function["name"] in found:
                        raise ValueError(f"Duplicate coverage for {function['name']}")
                    found[function["name"]] = function
    for name, minimum in functions.items():
        if name not in found:
            raise ValueError(f"Missing Swift coverage for {name}")
        function = found[name]
        covered, count = function["coveredLines"], function["executableLines"]
        if not 0 <= covered <= count or count == 0:
            raise ValueError(f"Invalid Swift coverage for {name}")
        print(f"{name}: {covered}/{count}; minimum {minimum:.0%}")
        if covered / count < minimum:
            raise ValueError(f"Line coverage below minimum for {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["rust", "swift"])
    parser.add_argument("current", type=pathlib.Path)
    parser.add_argument("--baseline", type=pathlib.Path)
    args = parser.parse_args()
    policy = json.loads(POLICY.read_text())
    current = json.loads(args.current.read_text())
    if args.kind == "rust":
        if args.baseline is None:
            parser.error("Rust coverage requires --baseline")
        check_rust(current, json.loads(args.baseline.read_text()), policy["rust_modules"])
    else:
        check_swift(current, policy["swift_functions"])


if __name__ == "__main__":
    main()
