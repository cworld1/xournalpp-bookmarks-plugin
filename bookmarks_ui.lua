-- A plain GTK bookmark list. The page labels live in text elements; this
-- dialog only presents them and delegates document changes to main.lua.
local M = {}

function M.open()
  local gi = require("LuaGObject")
  local Gtk = gi.require("Gtk", "3.0")
  local builder = Gtk.Builder()
  assert(builder:add_from_file(sourcePath .. "dlgBookmarks.glade"))
  local ui = builder.objects
  local dialog = ui.dlgBookmarks
  dialog:set_title("Bookmarks")
  -- Let GTK position the dialog relative to the Xournal++ window.
  dialog:set_position(Gtk.WindowPosition.CENTER)
  pcall(function()
    local parent, fallback
    for _, window in ipairs(Gtk.Window.list_toplevels()) do
      if window ~= dialog and window:get_visible() then
        fallback = fallback or window
        if (window:get_title() or ""):lower():find("xournal", 1, true) then
          parent = window
          break
        end
      end
    end
    parent = parent or fallback
    if parent then
      dialog:set_transient_for(parent)
      dialog:set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
    else
      dialog:set_position(Gtk.WindowPosition.CENTER)
    end
  end)

  local column = { PAGE = 1, NAME = 2, INDEX = 3 }
  local store = Gtk.ListStore.new {
    [column.PAGE] = gi.GObject.Type.UINT,
    [column.NAME] = gi.GObject.Type.STRING,
    [column.INDEX] = gi.GObject.Type.UINT
  }
  local tree = Gtk.TreeView {
    model = store,
    Gtk.TreeViewColumn {
      title = "Page",
      { Gtk.CellRendererText {}, {text = column.PAGE} }
    },
    Gtk.TreeViewColumn {
      title = "Bookmark", expand = true,
      { Gtk.CellRendererText {}, {text = column.NAME} }
    }
  }
  ui.scrolledWindow:add(tree)

  local bookmarks = {}
  local function refresh()
    store:clear()
    bookmarks = {}
    for _, t in ipairs(get_all_texts()) do
      local prefix, name = parse_bookmark(t.text or "")
      if prefix and t.page then
        bookmarks[#bookmarks + 1] = {
          page = t.page, layer = t.layer or 1, name = t.text,
          label = name, ref = t.ref, x = t.x, y = t.y
        }
      end
    end
    table.sort(bookmarks, function(a, b)
      if a.page ~= b.page then return a.page < b.page end
      if a.layer ~= b.layer then return a.layer < b.layer end
      return (a.y or 0) < (b.y or 0)
    end)
    for i, b in ipairs(bookmarks) do
      store:append({b.page, b.label, i})
    end
  end

  local function selected_bookmark()
    local model, iter = tree:get_selection():get_selected()
    if not iter then return nil end
    return bookmarks[model[iter][column.INDEX]]
  end

  function tree:on_row_activated(path)
    local first, second = store:get_iter(path)
    local iter = type(first) ~= "boolean" and first or second
    local b = iter and bookmarks[store[iter][column.INDEX]]
    if not b then return end
    app.clearSelection()
    app.setCurrentPage(b.page)
    set_current_layer_compat(b.layer)
    app.scrollToPage(b.page)
    dialog:destroy()
  end

  function ui.btnNew:on_clicked()
    new_bookmark()
    refresh()
  end

  function ui.btnRename:on_clicked()
    local b = selected_bookmark()
    if not b then return end

    local edit = Gtk.Dialog { title = "Rename Bookmark", transient_for = dialog, modal = true }
    edit:add_button("Cancel", Gtk.ResponseType.CANCEL)
    edit:add_button("Rename", Gtk.ResponseType.OK)
    local entry = Gtk.Entry()
    entry:set_text(b.label)
    entry:set_activates_default(true)
    edit:get_content_area():add(entry)
    edit:set_default_response(Gtk.ResponseType.OK)
    edit:set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
    edit:show_all()
    entry:grab_focus()
    local response = edit:run()
    local label = entry:get_text()
    edit:destroy()
    if response == Gtk.ResponseType.OK then
      local ok, err = rename_bookmark(b, label)
      if ok then
        refresh()
      else
        app.openDialog(err, {"OK"}, "", true)
      end
    end
  end

  function ui.btnDelete:on_clicked()
    local b = selected_bookmark()
    if not b then return end
    app.setCurrentPage(b.page)
    set_current_layer_compat(b.layer)
    local ref = resolve_bookmark_element(b)
    if not ref then
      app.openDialog("Bookmark not found in the current document.", {"OK"}, "", true)
      return
    end
    delete_bookmark(b.page, b.layer, ref)
    refresh()
  end

  refresh()
  dialog:show_all()
end

return M
