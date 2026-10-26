# Xournal++ Bookmarks Plugin

Bookmark navigation for Xournal++ with a GTK bookmark manager. On Windows, Xournal++ 1.3 and later ships `LuaGObject`, so there is no separate `lua-lgi` installation.

Forked from [xournalConfig](https://github.com/TamadoIchikai/xournalConfig) and [xournalpp-bookmarks-plugin](https://github.com/daisydaisyyy/xournalpp-bookmarks-plugin).

## Install

Copy this folder into Xournal++'s plugins directory, enable it in **Plugins > Plugin Manager**, and restart Xournal++. See the [Xournal++ plugin guide](https://xournalpp.github.io/guide/plugins/plugins/) for platform specific plugin locations.

## Use

- Press **B** to add a bookmark to the current page. The name comes from the PDF background's contents outline when available, such as `P9 Chapter 1 - Introduction`. If the PDF has no outline, the plugin looks for an explicit chapter or section heading in its text or the page's annotations. Otherwise it uses `P9 Bookmark`. Pressing **B** again on that page leaves the existing bookmark in place without selecting it or creating a duplicate.
- Press **Shift+B** to open the centered GTK bookmark list. Double-click a row to jump to it, or use **New**, **Rename**, and **Delete**.
- Use **Next Bookmark** and **Previous Bookmark** from the Plugins menu or toolbar for page navigation.

Bookmarks are text elements beginning with `*` or `->` (additional dashes create deeper levels). You can also create them directly with the text tool.
