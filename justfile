marp:
    marp --theme ./vimkim.css cubool.md

marp-pdf:
    marp --theme ./vimkim.css cubool.md --pdf

entr:
    echo cubool.md | entr marp --theme ./vimkim.css cubool.md
