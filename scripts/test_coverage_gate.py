"""Coverage gates must reject missing data and actual coverage regressions."""

import unittest

from coverage_gate import check_rust, check_swift


def rust(covered, count):
    return {
        "data": [
            {
                "files": [
                    {
                        "filename": "/checkout/src/core.rs",
                        "summary": {"lines": {"covered": covered, "count": count}},
                    }
                ]
            }
        ]
    }


def swift(covered, count):
    return {
        "targets": [
            {
                "name": "ParakattApp.framework",
                "files": [
                    {
                        "functions": [
                            {"name": "save()", "coveredLines": covered, "executableLines": count}
                        ]
                    }
                ],
            }
        ]
    }


class CoverageTests(unittest.TestCase):
    def test_rust_regression_and_missing_data_fail(self):
        for report in [rust(8, 10), {}, rust(0, 0)]:
            with self.subTest(report=report), self.assertRaises(ValueError):
                check_rust(report, rust(9, 10), ["src/core.rs"])

    def test_rust_compares_fractions_when_line_counts_change(self):
        check_rust(rust(18, 20), rust(9, 10), ["src/core.rs"])
        check_rust(rust(19, 20), rust(9, 10), ["src/core.rs"])
        with self.assertRaises(ValueError):
            check_rust(rust(17, 20), rust(9, 10), ["src/core.rs"])

    def test_swift_requires_named_function_and_all_expected_lines(self):
        for report in [swift(9, 10), swift(0, 0), {"targets": []}]:
            with self.subTest(report=report), self.assertRaises(ValueError):
                check_swift(report, {"save()": 1.0})
        check_swift(swift(10, 10), {"save()": 1.0})

    def test_swift_does_not_accept_test_target_or_duplicate_entries(self):
        report = swift(10, 10)
        report["targets"][0]["name"] = "Tests.xctest"
        with self.assertRaises(ValueError):
            check_swift(report, {"save()": 1.0})
        report = swift(10, 10)
        report["targets"].append(report["targets"][0])
        with self.assertRaises(ValueError):
            check_swift(report, {"save()": 1.0})


if __name__ == "__main__":
    unittest.main()
