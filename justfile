marp:
    marp --theme ./vimkim.css cubool.md -o docs/index.html

marp-pdf:
    marp --theme ./vimkim.css cubool.md --pdf

entr:
    echo cubool.md | entr marp --theme ./vimkim.css cubool.md
