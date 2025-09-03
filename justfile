marp:
    marp --theme ./vimkim.css cubool.md

entr:
    echo cubool.md | entr marp --theme ./vimkim.css cubool.md
