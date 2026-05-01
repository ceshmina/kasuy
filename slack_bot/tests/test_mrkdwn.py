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

    def test_dash_list_to_bullet(self) -> None:
        self.assert_convert("- one\n- two", "• one\n• two")

    def test_star_list_to_bullet(self) -> None:
        self.assert_convert("* one\n* two", "• one\n• two")

    def test_ordered_list(self) -> None:
        self.assert_convert("1. one\n2. two", "1. one\n2. two")

    def test_star_list_with_inline_bold(self) -> None:
        self.assert_convert("* list **bold** here", "• list *bold* here")

    def test_nested_list_uses_subbullets(self) -> None:
        self.assert_convert(
            "- one\n  - sub\n  - sub2\n- two",
            "• one\n  ◦ sub\n  ◦ sub2\n• two",
        )

    def test_double_dash_flag_not_bulleted(self) -> None:
        self.assert_convert("--verbose flag", "--verbose flag")

    def test_horizontal_rule_dashes(self) -> None:
        self.assert_convert(
            "Above\n\n---\n\nBelow",
            "Above\n\n" + ("─" * 20) + "\n\nBelow",
        )

    def test_horizontal_rule_stars(self) -> None:
        self.assert_convert(
            "Above\n\n***\n\nBelow",
            "Above\n\n" + ("─" * 20) + "\n\nBelow",
        )

    def test_horizontal_rule_underscores(self) -> None:
        self.assert_convert(
            "Above\n\n___\n\nBelow",
            "Above\n\n" + ("─" * 20) + "\n\nBelow",
        )

    def test_long_dash_line_is_hr(self) -> None:
        self.assert_convert("------", "─" * 20)

    def test_indented_hr(self) -> None:
        self.assert_convert("  ---", "─" * 20)

    def test_hr_inside_code_block_preserved(self) -> None:
        source = "```\n---\n***\n```"
        self.assert_convert(source, source)

    def test_simple_table_wrapped_in_code_fence(self) -> None:
        table = "| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |"
        expected = (
            "```\n| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |\n```"
        )
        self.assert_convert(table, expected)

    def test_aligned_table_wrapped_in_code_fence(self) -> None:
        table = "| Col | Val |\n| :--- | ---: |\n| a | 1 |"
        expected = "```\n| Col | Val |\n| :--- | ---: |\n| a | 1 |\n```"
        self.assert_convert(table, expected)

    def test_table_with_following_paragraph(self) -> None:
        source = "| h |\n|---|\n| a |\n\nAfter"
        expected = "```\n| h |\n|---|\n| a |\n```\n\nAfter"
        self.assert_convert(source, expected)

    def test_table_content_not_treated_as_bold(self) -> None:
        source = "| **x** | y |\n|---|---|\n| a | b |"
        expected = "```\n| **x** | y |\n|---|---|\n| a | b |\n```"
        self.assert_convert(source, expected)

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
