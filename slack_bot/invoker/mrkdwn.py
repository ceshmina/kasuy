"""Convert standard Markdown to Slack mrkdwn format."""
import re

_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`\n]+`")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_HEADING_RE = re.compile(r"^#{1,6}[^\S\n]+(.+?)[^\S\n]*$", re.MULTILINE)
_BOLD_STAR_RE = re.compile(r"\*\*([^\s*](?:.*?[^\s*])?)\*\*", re.DOTALL)
_BOLD_UNDER_RE = re.compile(r"__([^\s_](?:.*?[^\s_])?)__", re.DOTALL)
_INNER_BOLD_STAR_RE = re.compile(r"\*\*(.+?)\*\*", re.DOTALL)
_INNER_BOLD_UNDER_RE = re.compile(r"__(.+?)__", re.DOTALL)
_ITALIC_STAR_RE = re.compile(r"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![*\w])")
_ITALIC_UNDER_RE = re.compile(r"(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])")
_STRIKE_RE = re.compile(r"~~(.+?)~~", re.DOTALL)
_PLACEHOLDER_RE = re.compile(r"\x00P(\d+)\x00")

_BOLD_OPEN = "\x00B\x00"
_BOLD_CLOSE = "\x00b\x00"


def _heading_repl(match: "re.Match[str]") -> str:
    inner = match.group(1)
    inner = _INNER_BOLD_STAR_RE.sub(r"\1", inner)
    inner = _INNER_BOLD_UNDER_RE.sub(r"\1", inner)
    return f"{_BOLD_OPEN}{inner}{_BOLD_CLOSE}"


def to_mrkdwn(text: str) -> str:
    stashed: list[str] = []

    def stash(match: "re.Match[str]") -> str:
        stashed.append(match.group(0))
        return f"\x00P{len(stashed) - 1}\x00"

    text = _FENCE_RE.sub(stash, text)
    text = _INLINE_CODE_RE.sub(stash, text)

    text = _LINK_RE.sub(lambda m: f"<{m.group(2)}|{m.group(1)}>", text)
    text = _HEADING_RE.sub(_heading_repl, text)

    text = _BOLD_STAR_RE.sub(lambda m: f"{_BOLD_OPEN}{m.group(1)}{_BOLD_CLOSE}", text)
    text = _BOLD_UNDER_RE.sub(lambda m: f"{_BOLD_OPEN}{m.group(1)}{_BOLD_CLOSE}", text)

    text = _ITALIC_STAR_RE.sub(lambda m: f"_{m.group(1)}_", text)
    text = _ITALIC_UNDER_RE.sub(lambda m: f"_{m.group(1)}_", text)

    text = text.replace(_BOLD_OPEN, "*").replace(_BOLD_CLOSE, "*")

    text = _STRIKE_RE.sub(lambda m: f"~{m.group(1)}~", text)

    text = _PLACEHOLDER_RE.sub(lambda m: stashed[int(m.group(1))], text)
    return text
