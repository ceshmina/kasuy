import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "invoker"))

from mrkdwn import to_mrkdwn


class ToMrkdwnTest(unittest.TestCase):
    def assert_convert(self, source: str, expected: str) -> None:
        self.assertEqual(to_mrkdwn(source), expected)

    def test_h1_heading(self) -> None:
        self.assert_convert("# Title", "*Title*")

    def test_h2_heading(self) -> None:
        self.assert_convert("## Subhead", "*Subhead*")

    def test_consecutive_headings(self) -> None:
        self.assert_convert("# A\n## B\n### C", "*A*\n*B*\n*C*")

    def test_heading_preserves_blank_line(self) -> None:
        self.assert_convert(
            "# Heading\n\nBody **text** here.",
            "*Heading*\n\nBody *text* here.",
        )

    def test_heading_strips_inner_bold(self) -> None:
        self.assert_convert("# H with **bold**", "*H with bold*")

    def test_bold_star(self) -> None:
        self.assert_convert("**bold**", "*bold*")

    def test_bold_underscore(self) -> None:
        self.assert_convert("__bold__", "*bold*")

    def test_bold_mixed(self) -> None:
        self.assert_convert(
            "**bold** and __also bold__",
            "*bold* and *also bold*",
        )

    def test_italic_star(self) -> None:
        self.assert_convert("*italic*", "_italic_")

    def test_italic_underscore(self) -> None:
        self.assert_convert("_italic_", "_italic_")

    def test_bold_and_italic(self) -> None:
        self.assert_convert(
            "Mix: **bold** with *italic* :rocket:",
            "Mix: *bold* with _italic_ :rocket:",
        )

    def test_triple_asterisk_bold_italic(self) -> None:
        self.assert_convert("nested ***boldit*** sample", "nested _*boldit*_ sample")

    def test_strikethrough(self) -> None:
        self.assert_convert("~~strike~~", "~strike~")

    def test_link(self) -> None:
        self.assert_convert(
            "[Anthropic](https://anthropic.com)",
            "<https://anthropic.com|Anthropic>",
        )

    def test_link_with_underscore_in_url(self) -> None:
        self.assert_convert(
            "Click [here](https://example.com/a_b_c) now",
            "Click <https://example.com/a_b_c|here> now",
        )

    def test_unordered_list(self) -> None:
        self.assert_convert("- item one\n- item two", "- item one\n- item two")

    def test_ordered_list(self) -> None:
        self.assert_convert("1. one\n2. two", "1. one\n2. two")

    def test_star_list_with_inline_bold(self) -> None:
        self.assert_convert("* list **bold** here", "* list *bold* here")

    def test_blockquote_passthrough(self) -> None:
        self.assert_convert("> quoted line", "> quoted line")

    def test_inline_code_passthrough(self) -> None:
        self.assert_convert("inline `code` here", "inline `code` here")

    def test_fenced_code_block_protects_content(self) -> None:
        self.assert_convert(
            "```\n**not bold**\n```",
            "```\n**not bold**\n```",
        )

    def test_code_block_with_surrounding_text(self) -> None:
        self.assert_convert(
            "text\n\n```python\ndef f():\n    return **2**\n```\n\nend",
            "text\n\n```python\ndef f():\n    return **2**\n```\n\nend",
        )

    def test_inline_code_with_underscores_preserved(self) -> None:
        self.assert_convert(
            "ファイル名: `data_2026.csv` を確認",
            "ファイル名: `data_2026.csv` を確認",
        )

    def test_snake_case_identifier_not_italicized(self) -> None:
        self.assert_convert("snake_case_var stays put", "snake_case_var stays put")

    def test_arithmetic_asterisks_not_italicized(self) -> None:
        self.assert_convert(
            "multiplication 2 * 3 * 4 stays",
            "multiplication 2 * 3 * 4 stays",
        )

    def test_japanese_bold_and_italic(self) -> None:
        self.assert_convert("**太字** と *斜体*", "*太字* と _斜体_")

    def test_empty_string(self) -> None:
        self.assert_convert("", "")

    def test_plain_text_unchanged(self) -> None:
        self.assert_convert("just plain text", "just plain text")


if __name__ == "__main__":
    unittest.main()
