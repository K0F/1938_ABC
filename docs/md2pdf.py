#!/usr/bin/env python3
"""Convert Markdown to HTML (--html, default) or PDF (--pdf) via pango/cairo."""

import argparse
import html
import os
import re
from html.parser import HTMLParser

import markdown


class _HtmlToPango(HTMLParser):
    """Convert HTML from markdown to Pango markup for cairo rendering."""

    def __init__(self):
        super().__init__()
        self._out = []
        self._tag_stack = []
        self._in_pre = False
        self._in_table = False
        self._table_rows = []
        self._cur_cells = []
        self._cur_is_header = False
        self._link_href = None
        self._list_depth = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self._tag_stack.append(tag)

        if tag == "pre":
            self._in_pre = True
            self._nl(2)
        elif tag == "code" and self._in_pre:
            pass  # text handled in data
        elif tag == "code":
            self._out.append('<span font="DejaVu Sans Mono" size="small">')
        elif tag in ("strong", "b"):
            self._out.append("<b>")
        elif tag in ("em", "i"):
            self._out.append("<i>")
        elif tag == "a":
            self._link_href = a.get("href", "")
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._nl(2)
        elif tag == "p":
            self._nl(1)
        elif tag == "br":
            self._out.append("\n")
        elif tag == "hr":
            self._nl(2)
            self._out.append("─" * 60)
            self._nl(1)
        elif tag in ("ul", "ol"):
            self._list_depth += 1
            self._nl(1)
        elif tag == "li":
            self._nl(1)
            self._out.append("  " * (self._list_depth - 1) + "• ")
        elif tag == "table":
            self._in_table = True
            self._table_rows = []
            self._nl(2)
        elif tag == "tr":
            self._cur_cells = []
        elif tag == "th":
            self._cur_is_header = True
        elif tag == "td":
            self._cur_is_header = False
        elif tag == "blockquote":
            self._nl(2)

    def handle_endtag(self, tag):
        if self._tag_stack and self._tag_stack[-1] == tag:
            self._tag_stack.pop()

        if tag == "pre":
            self._in_pre = False
            self._nl(2)
        elif tag == "code" and not self._in_pre:
            self._out.append("</span>")
        elif tag in ("strong", "b"):
            self._out.append("</b>")
        elif tag in ("em", "i"):
            self._out.append("</i>")
        elif tag == "a":
            if self._link_href:
                self._out.append(f" ({self._link_href})")
            self._link_href = None
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._nl(2)
        elif tag == "p":
            self._nl(2)
        elif tag in ("ul", "ol"):
            self._list_depth = max(0, self._list_depth - 1)
            self._nl(1)
        elif tag == "tr":
            self._table_rows.append((self._cur_is_header, list(self._cur_cells)))
        elif tag == "table":
            self._flush_table()
            self._in_table = False
            self._nl(2)
        elif tag == "blockquote":
            self._nl(2)

    def handle_data(self, data):
        if self._in_pre:
            # strip <code> tags from inside <pre>, escape for Pango
            cleaned = re.sub(r"</?code[^>]*>", "", data)
            cleaned = (
                cleaned.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            )
            self._out.append(cleaned)
            return

        text = html.unescape(data)

        if self._in_table and self._tag_stack:
            top = self._tag_stack[-1]
            if top in ("th", "td"):
                text = text.strip()
                text = (
                    text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                )
                if self._cur_is_header:
                    self._cur_cells.append(f"<b>{text}</b>")
                else:
                    self._cur_cells.append(text)
                return

        escaped = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        self._out.append(escaped)

    def _nl(self, n=1):
        self._out.append("\n" * n)

    def _flush_table(self):
        if not self._table_rows:
            return
        for idx, (is_hdr, cells) in enumerate(self._table_rows):
            row = " │ ".join(cells)
            self._out.append(row)
            self._nl(1)
            if idx == 0:
                self._out.append("─" * 60)
                self._nl(1)
        self._nl(1)

    def result(self):
        raw = "".join(self._out)
        raw = re.sub(r"\n{3,}", "\n\n", raw)
        return raw.strip() + "\n"


def html_to_pango(html_body):
    p = _HtmlToPango()
    p.feed(html_body)
    return p.result()


CSS = """\
@page { size: A4; margin: 18mm 16mm; }
body { font-family: 'DejaVu Sans', 'Noto Sans', sans-serif; font-size: 10pt;
       line-height: 1.45; color: #1a1a1a; }
h1 { font-size: 20pt; border-bottom: 2px solid #333; padding-bottom: 4px;
     page-break-before: auto; }
h2 { font-size: 15pt; border-bottom: 1px solid #999; padding-bottom: 2px;
     margin-top: 18px; }
h3 { font-size: 12pt; margin-top: 14px; }
h4 { font-size: 11pt; margin-top: 12px; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 9pt; }
th, td { border: 1px solid #bbb; padding: 3px 6px; text-align: left; vertical-align: top; }
th { background: #eeeeee; }
code { font-family: 'DejaVu Sans Mono', monospace; font-size: 8.5pt;
       background: #f4f4f4; padding: 0 2px; }
pre { background: #f4f4f4; border: 1px solid #ddd; padding: 6px;
      font-size: 8.5pt; line-height: 1.3; white-space: pre-wrap; }
blockquote { border-left: 3px solid #ccc; margin: 6px 0; padding: 2px 10px;
             color: #444; }
a { color: #1155cc; text-decoration: none; }
ul, ol { margin: 4px 0; }
li { margin: 2px 0; }
hr { border: 0; border-top: 1px solid #999; }
"""


def title_block(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(r"^#\s+(.+)$", text, re.M)
    title = m.group(1) if m else os.path.basename(path)
    return html.escape(title), text


def convert_html(md_path):
    root = os.path.splitext(md_path)[0]
    t, text = title_block(md_path)
    body = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "sane_lists"],
    )
    html_txt = (
        '<!DOCTYPE html>\n<html lang="cs">\n<head>\n'
        '<meta charset="utf-8">\n<title>%s</title>\n'
        "<style>%s</style>\n</head>\n<body>\n%s\n</body>\n</html>\n" % (t, CSS, body)
    )
    html_path = root + ".html"
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_txt)
    print("html:", html_path)


def convert_pdf(md_path, out_path=None):
    import gi

    gi.require_version("Pango", "1.0")
    gi.require_version("PangoCairo", "1.0")
    from gi.repository import Pango, PangoCairo
    import cairo

    root = os.path.splitext(md_path)[0]
    t, text = title_block(md_path)
    body = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "sane_lists"],
    )

    pdf_path = out_path or (root + ".pdf")
    page_w, page_h = 595.28, 841.89
    margin = 18 * 2.835
    usable_w = page_w - 2 * margin
    usable_h = page_h - 2 * margin

    pango_text = html_to_pango(body)

    fd = Pango.FontDescription("DejaVu Sans")
    fd.set_size(9 * Pango.SCALE)

    surface = cairo.PDFSurface(pdf_path, page_w, page_h)

    def make_ctx():
        return cairo.Context(surface)

    def make_layout(ctx):
        lay = PangoCairo.create_layout(ctx)
        lay.set_font_description(fd)
        lay.set_width(int(usable_w * Pango.SCALE))
        lay.set_wrap(Pango.WrapMode.WORD_CHAR)
        return lay

    def text_height(ctx, txt):
        lay = make_layout(ctx)
        lay.set_markup(txt, -1)
        return lay.get_pixel_size()[1]

    ctx = make_ctx()

    # render title
    lay = make_layout(ctx)
    title_plain = html.unescape(re.sub(r"<[^>]+>", "", t))
    escaped = (
        title_plain.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )
    lay.set_markup(f"<b>{escaped}</b>", -1)
    ctx.move_to(margin, margin)
    PangoCairo.show_layout(ctx, lay)
    h = lay.get_pixel_size()[1]
    ctx.move_to(margin, margin + h + 2)
    ctx.line_to(page_w - margin, margin + h + 2)
    ctx.set_line_width(0.5)
    ctx.stroke()
    y = margin + h + 8

    # split into paragraphs
    paragraphs = re.split(r"\n\n+", pango_text)

    for para in paragraphs:
        if not para.strip():
            continue

        # measure paragraph height on a throwaway context
        test_ctx = make_ctx()
        ph = text_height(test_ctx, para)

        if ph <= usable_h:
            # fits on one page — check if it fits on current page
            if y + ph > page_h - margin:
                surface.show_page()
                ctx = make_ctx()
                y = margin
            lay = make_layout(ctx)
            lay.set_markup(para, -1)
            ctx.move_to(margin, y)
            PangoCairo.show_layout(ctx, lay)
            y += lay.get_pixel_size()[1]
        else:
            # too tall — split by lines
            lines = para.split("\n")
            i = 0
            while i < len(lines):
                # find how many lines from i fit on page
                chunk_lines = []
                for j in range(i, len(lines)):
                    test = "\n".join(lines[i : j + 1])
                    if text_height(ctx, test) > usable_h:
                        break
                    chunk_lines.append(lines[j])
                if not chunk_lines:
                    chunk_lines = [lines[i]]
                chunk = "\n".join(chunk_lines)
                i += len(chunk_lines)

                if y + text_height(ctx, chunk) > page_h - margin:
                    surface.show_page()
                    ctx = make_ctx()
                    y = margin

                lay = make_layout(ctx)
                lay.set_markup(chunk, -1)
                ctx.move_to(margin, y)
                PangoCairo.show_layout(ctx, lay)
                y += lay.get_pixel_size()[1]

    surface.finish()
    print("pdf:", pdf_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--output", help="Output PDF path (implies --pdf)")
    ap.add_argument(
        "--pdf", action="store_true", help="Output PDF via pango/cairo instead of HTML"
    )
    args = ap.parse_args()
    use_pdf = args.pdf or args.output
    for fn in args.files:
        if use_pdf:
            convert_pdf(fn, out_path=args.output)
        else:
            convert_html(fn)


if __name__ == "__main__":
    main()
