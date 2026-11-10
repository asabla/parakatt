import unittest
from types import SimpleNamespace

from parakatt_linux.meeting_notes import render_minutes


class MinutesTests(unittest.TestCase):
    def test_missing_owners_dates_and_timestamps_are_not_invented(self):
        cue = SimpleNamespace(
            text="Review <script>alert(1)</script> [link](https://example.com)",
            speaker=None,
            start_secs=None,
        )
        action = SimpleNamespace(
            text="Review contract",
            owner=None,
            due_date=None,
            completed=False,
            source_utterance=0,
            source_quote=cue.text,
        )
        output = render_minutes("Meeting", "teams", "id", [cue], [action], "User's edited notes")
        self.assertIn("- [ ] Review contract", output)
        self.assertIn("## Edited notes", output)
        self.assertNotIn("<script>", output)
        self.assertIn("\\[link\\]", output)
        self.assertNotIn("0.000s", output)
        self.assertNotIn("Owner:", output)


if __name__ == "__main__":
    unittest.main()
