#!/usr/bin/env python3
import argparse
import html
import os
import re
import sys

import markdown

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


def convert(md_path):
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()
    for fn in args.files:
        convert(fn)


if __name__ == "__main__":
    main()
