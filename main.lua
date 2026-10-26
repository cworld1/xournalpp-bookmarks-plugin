utf8_to_html = require("utf8_to_html")
local bookmarks_ui = require("bookmarks_ui")
local pdf_text = require("pdf_text")

DEFAULT_EXPORT_PATH = "/tmp/temp"

-- Centralized Bookmark Parsing
function parse_bookmark(txt)
  local prefix, content = txt:match("^(%*)%s*(.*)")
  if not prefix then
    prefix, content = txt:match("^(%-+>)%s*(.*)")
  end
  return prefix, content
end

-- Set current layer in a version-tolerant way.
function set_current_layer_compat(layer)
  if not layer then return false end
  local ok = pcall(app.setCurrentLayer, layer, false)
  if ok then return true end
  return pcall(app.setCurrentLayer, layer)
end

-- Decode the XML entities used inside .xopp text elements.
function xml_unescape(str)
  if not str then return "" end

  local function utf8_char(code)
    code = tonumber(code)
    if not code then return "" end

    if utf8 and utf8.char then
      local ok, ch = pcall(utf8.char, code)
      if ok and ch then return ch end
    end
    if code >= 0 and code <= 127 then return string.char(code) end
    return ""
  end

  str = str:gsub("&#x(%x+);", function(hex) return utf8_char(tonumber(hex, 16)) end)
  str = str:gsub("&#(%d+);", function(dec) return utf8_char(tonumber(dec, 10)) end)
  str = str:gsub("&quot;", "\"")
  str = str:gsub("&apos;", "'")
  str = str:gsub("&lt;", "<")
  str = str:gsub("&gt;", ">")
  str = str:gsub("&amp;", "&")
  return str
end

function xml_attr(attrs, name)
  if not attrs then return nil end
  local value = attrs:match(name .. '="([^"]*)"')
  if value then return xml_unescape(value) end
  value = attrs:match(name .. "='([^']*)'")
  if value then return xml_unescape(value) end
  return nil
end

-- Read the saved .xopp file without changing the visible page.
-- Uses a pure-Lua gzip/Deflate decompressor (inflate.lua) so it works on any
-- platform, including Windows where the `gzip` binary is not available. The
-- .xopp format is gzip-compressed XML; we decompress it in memory and return
-- the XML text for all pages.
function read_xopp_xml_from_disk()
  local inflate = require("inflate")
  local structure = app.getDocumentStructure()
  local filename = structure and structure.xoppFilename
  if not filename or filename == "" then return nil end

  local ok, bytes = pcall(function()
    local fh = io.open(filename, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
  end)
  if not ok or not bytes then return nil end

  return inflate.gunzip(bytes)
end

-- Cache of get_all_texts() results. Keyed by page/layer structure so repeated
-- calls (e.g. Next/Previous Bookmark navigation) stay instant; cleared on any
-- plugin bookmark mutation (create/edit/delete). A short TTL bounds staleness
-- if text is changed directly in the document (outside the plugin).
local allTextsCache = nil
local CACHE_TTL = 3.0

-- Compact signature of the document structure: page count + layer count per
-- page. Any change here invalidates cached text lists.
local function structure_cache_sig(structure)
  local parts = { tostring(#(structure.pages or {})) }
  for p = 1, #(structure.pages or {}) do
    local pi = structure.pages[p]
    parts[#parts + 1] = ":" .. tostring(pi and #(pi.layers or {}) or 0)
  end
  return table.concat(parts)
end

-- Copy a text element returned by the native getTexts() API, tagging it with
-- the page/layer it came from (unless the element already carries them).
local function annotate_text(t, page, layer)
  local item = {}
  for k, v in pairs(t) do item[k] = v end
  item.page = item.page or page
  item.layer = item.layer or layer
  return item
end

-- Silent background save triggered only when bookmarks are altered.
function save_document_silently()
  -- Any save from this plugin invalidates the cached text list; bookmarks may
  -- have been added/edited/removed.
  allTextsCache = nil

  local structure = app.getDocumentStructure()
  local filename = structure and structure.xoppFilename

  if not filename or filename == "" then
    pcall(app.activateAction, "save-as")
    pcall(app.activateAction, "document-save-as")
    pcall(app.uiAction, { action = "ACTION_SAVE_AS" })
    return false
  end

  local attempted = false
  local actionNames = {"save", "document-save", "file-save"}

  for _, actionName in ipairs(actionNames) do
    local ok = pcall(app.activateAction, actionName)
    attempted = attempted or ok
    if ok then break end
  end

  if not attempted then
    pcall(app.uiAction, { action = "ACTION_SAVE" })
  end

  return true
end

-- Fast, unified text reader. Replaces both old text fetchers.
function get_all_texts()
  local structure = app.getDocumentStructure()
  if not structure or not structure.pages or #structure.pages == 0 then
    return {}
  end

  local sig = structure_cache_sig(structure)
  if allTextsCache and allTextsCache.sig == sig
     and os.clock() - (allTextsCache.t or 0) < CACHE_TTL then
    return allTextsCache.texts
  end

  local texts, complete
  local okAll, allTexts = pcall(app.getTexts, "all")
  if okAll and type(allTexts) == "table" and #allTexts > 0 then
    texts, complete = allTexts, true
  else
    texts, complete = read_all_texts_native(structure)
    if not complete then
      texts, complete = read_all_texts_fallback(structure, texts)
    end
  end

  if complete then
    allTextsCache = { sig = sig, texts = texts, t = os.clock() }
  end
  return texts
end

-- Read every page (and every real layer) through the native getTexts("layer")
-- API. This is far faster on large files than decompressing the .xopp and
-- always reflects the live in-memory document. setCurrentPage/setCurrentLayer
-- do not scroll the view or change layer visibility; the original page + layer
-- are restored. Returns (texts, complete).
function read_all_texts_native(structure)
  local texts = {}
  local origPage = structure.currentPage or 1

  local ok = pcall(function()
    for p = 1, #structure.pages do
      app.setCurrentPage(p)
      local pageInfo = structure.pages[p]
      -- layers is 0-indexed: [0]=background, [1..N]=real layers. The `#`
      -- operator counts the 1-based trailing entries, i.e. the real layers.
      local nLayers = math.max(1, #(pageInfo.layers or {}))
      for l = 1, nLayers do
        pcall(app.setCurrentLayer, l, false)
        local okL, layerTexts = pcall(app.getTexts, "layer")
        if okL and type(layerTexts) == "table" then
          for _, t in ipairs(layerTexts) do
            table.insert(texts, annotate_text(t, p, l))
          end
        end
      end
    end
  end)

  -- Restore the original page and layer in all cases.
  pcall(app.setCurrentPage, origPage)
  local origInfo = structure.pages[origPage]
  if origInfo then
    pcall(app.setCurrentLayer, origInfo.currentLayer or 1, false)
  end

  return texts, ok and #texts > 0
end

-- Read all text elements from the on-disk .xopp file (works everywhere), and
-- if that is not possible, fall back to the current page's active layer.
function read_all_texts_fallback(structure, texts)
  local xml = read_xopp_xml_from_disk()
  if xml then
    local result = {}
    local pageNr = 0

    for pageAttrs, pageBody in xml:gmatch("<page([^>]*)>(.-)</page>") do
      pageNr = pageNr + 1
      local layerNr = 0

      for layerAttrs, layerBody in pageBody:gmatch("<layer([^>]*)>(.-)</layer>") do
        layerNr = layerNr + 1

        for textAttrs, encodedText in layerBody:gmatch("<text%s+([^>]*)>(.-)</text>") do
          table.insert(result, {
            text = xml_unescape(encodedText),
            page = pageNr,
            layer = layerNr,
            x = tonumber(xml_attr(textAttrs, "x")) or 0,
            y = tonumber(xml_attr(textAttrs, "y")) or 0,
            color = xml_attr(textAttrs, "color"),
            font = {
              name = xml_attr(textAttrs, "font") or "Sans Regular",
              size = tonumber(xml_attr(textAttrs, "size")) or 12.0
            },
            ref = nil
          })
        end
      end
    end

    -- A non-nil xml means the on-disk file was read and decompressed, so its
    -- result is authoritative for the whole document even if it has no texts.
    return result, true
  end

  -- Unsaved document with no file on disk: read just the current page's
  -- active layer via the native API. This is the only incomplete case, so it
  -- is not cached.
  local currentPage = structure.currentPage or 1
  local okLayer, layerTexts = pcall(app.getTexts, "layer")
  if okLayer and type(layerTexts) == "table" then
    for _, t in ipairs(layerTexts) do
      table.insert(texts, annotate_text(t, currentPage))
    end
  end
  return texts, false
end

function text_coord_close(a, b)
  if a == nil or b == nil then return true end
  return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 0.75
end

-- Resolve a bookmark row from the no-reload list into a live element ref.
function resolve_bookmark_element(bookmark)
  if not bookmark then return nil end
  if bookmark.ref then return bookmark.ref, bookmark end

  app.setCurrentPage(bookmark.page)
  set_current_layer_compat(bookmark.layer or 1)

  local okTexts, layerTexts = pcall(app.getTexts, "layer")
  if not okTexts or type(layerTexts) ~= "table" then return nil end

  local fallback = nil
  for _, t in ipairs(layerTexts) do
    if (t.text or "") == (bookmark.name or bookmark.text or "") then
      fallback = fallback or t

      if text_coord_close(t.x, bookmark.x) and text_coord_close(t.y, bookmark.y) then
        bookmark.ref = t.ref
        bookmark.x = t.x
        bookmark.y = t.y
        bookmark.color = t.color
        bookmark.font = t.font
        return t.ref, t
      end
    end
  end

  if fallback then
    bookmark.ref = fallback.ref
    bookmark.x = fallback.x
    bookmark.y = fallback.y
    bookmark.color = fallback.color
    bookmark.font = fallback.font
    return fallback.ref, fallback
  end

  return nil
end

-- Keep bookmark text legible without making it look like a page heading.
-- Change these values to adjust the marker size for new or edited bookmarks.
BOOKMARK_TOP_LEVEL_SIZE = 10.0
BOOKMARK_CHILD_SIZE = 9.0
BOOKMARK_MIN_SIZE = 8.0
BOOKMARK_COLOR = 0x666666
BOOKMARK_FONT_FAMILY = package.config:sub(1, 1) == "\\" and "Segoe UI" or "Sans"

-- Centralized Bookmark Styling
function get_bookmark_style(text)
  local regular = BOOKMARK_FONT_FAMILY .. " Regular"
  local emphasis = BOOKMARK_FONT_FAMILY .. (BOOKMARK_FONT_FAMILY == "Segoe UI" and " Semibold" or " Medium")
  local fontName = regular
  local fontSize = BOOKMARK_TOP_LEVEL_SIZE

  if text:match("^%*") then
    fontName = emphasis
  elseif text:match("^%-+>") then
    local depth = string.len(text:match("^(%-+)>"))
    fontSize = math.max(BOOKMARK_MIN_SIZE, BOOKMARK_CHILD_SIZE - (depth - 1))
  end
  return fontName, fontSize
end

-- Register Toolbar
function initUi()
  app.registerUi({menu="Previous Bookmark", toolbarId="CUSTOM_PREVIOUS_BOOKMARK", callback="search_bookmark", mode=-1, iconName="go-previous"})
  app.registerUi({menu="New Bookmark", toolbarId="CUSTOM_NEW_BOOKMARK", callback="dialog_new_bookmark", iconName="bookmark-new-symbolic", ["accelerator"]="B"})
  app.registerUi({menu="New Bookmark (No dialog)", toolbarId="CUSTOM_NEW_BOOKMARK_NO_DIALOG", callback="new_bookmark_no_dialog", iconName="bookmark-new-symbolic"})
  app.registerUi({menu="Next Bookmark", toolbarId="CUSTOM_NEXT_BOOKMARK", callback="search_bookmark", mode=1, iconName="go-next"})
  app.registerUi({menu="View Bookmarks", toolbarId="CUSTOM_VIEW_BOOKMARKS", callback = "view_bookmarks", iconName="user-bookmarks-symbolic", ["accelerator"]="<Shift>B"})
  app.registerUi({menu="Restyle Existing Bookmarks", callback="compact_existing_bookmarks", iconName="format-text-small-symbolic"})
  app.registerUi({menu="Export to PDF with Bookmarks", toolbarId="CUSTOM_EXPORT_WITH_BOOKMARKS", callback="export", iconName="xopp-document-export-pdf"})

  local sep = package.config:sub(1,1)
  sourcePath = debug.getinfo(1).source:match("@?(.*" .. sep .. ")")
  if sep == "\\" then DEFAULT_EXPORT_PATH = "%TEMP%\\temp" end
end

local function current_page_texts(page)
  local ok, texts = pcall(app.getTexts, "page")
  if ok and type(texts) == "table" then return texts end

  local result = {}
  for _, t in ipairs(get_all_texts()) do
    if t.page == page then result[#result + 1] = t end
  end
  return result
end

local function bookmark_title_from_texts(texts)
  local best, best_chapter, best_y, best_x = nil, -1, math.huge, math.huge
  for _, t in ipairs(texts) do
    if not parse_bookmark(t.text or "") then
      local line = (t.text or ""):match("^[^\r\n]*") or ""
      line = line:gsub("%s+", " "):match("^%s*(.-)%s*$")
      local lower = line:lower()
      local chapter = lower:match("^chapter%s+%d+") and 1 or 0
      local section = lower:match("^section%s+[%d%.]+") or line:match("^%d+%.%d+%s+")
      if line ~= "" and (chapter == 1 or section) then
        local y, x = tonumber(t.y) or 0, tonumber(t.x) or 0
        if chapter > best_chapter or
           (chapter == best_chapter and (y < best_y or (y == best_y and x < best_x))) then
          best, best_chapter, best_y, best_x = line, chapter, y, x
        end
      end
    end
  end

  return best
end

local function bookmark_name_for_page(structure, texts, page)
  local title = pdf_text.get_section_title(structure, page)
  if not title then
    local pdf_content = pdf_text.get_page_text(structure, page)
    local pdf_lines = {}
    if pdf_content then
      for line in pdf_content:gmatch("[^\r\n]+") do
        pdf_lines[#pdf_lines + 1] = {text = line, y = #pdf_lines + 1, x = 0}
      end
    end
    title = bookmark_title_from_texts(pdf_lines)
        or bookmark_title_from_texts(texts) or "Bookmark"
  end
  local chapter_number, chapter_title = title:match("^[Cc]hapter%s+(%d+)%s*(.*)$")
  if chapter_number and chapter_title then
    chapter_title = chapter_title:gsub("^[%s%p]+", "")
    if chapter_title ~= "" then
      title = "Chapter " .. chapter_number .. " - " .. chapter_title
    end
  end
  if utf8 and utf8.offset then
    local after_limit = utf8.offset(title, 61)
    if after_limit then title = title:sub(1, after_limit - 1) .. "…" end
  end
  return "* P" .. page .. " " .. title
end

function new_bookmark()
  local structure = app.getDocumentStructure()
  local page = structure.currentPage
  local pageTexts = current_page_texts(page)
  for _, t in ipairs(pageTexts) do
    if parse_bookmark(t.text or "") then
      local ref = t.ref or resolve_bookmark_element({
        page = page, layer = t.layer or 1, name = t.text, x = t.x, y = t.y
      })
      app.clearSelection()
      return ref and {ref} or nil, t.text, false
    end
  end

  local name = bookmark_name_for_page(structure, pageTexts, page)

  local newFontName, newFontSize = get_bookmark_style(name)

  local refs = app.addTexts({
    texts = {
      { text = name, x = 12, y = 10, color = BOOKMARK_COLOR, font = { name = newFontName, size = newFontSize } }
    }
  })

  if refs and #refs > 0 then
    app.clearSelection()
    app.scrollToPage(page)
    app.refreshPage()
  end

  -- Invalidate the cached text list so later reads see the new bookmark. We do
  -- not trigger an immediate disk save here: it reloads/resets the document.
  -- The change stays in memory and in Xournal++'s undo stack until the next save.
  allTextsCache = nil

  return refs, name, true
end

function new_bookmark_no_dialog()
  return new_bookmark()
end

-- Apply the current font, size, and color to existing bookmark labels while
-- preserving their names and positions. Add before deleting the original.
function compact_existing_bookmarks()
  local structure = app.getDocumentStructure()
  local originalPage = structure.currentPage or 1
  local originalLayer = structure.pages[originalPage]
      and structure.pages[originalPage].currentLayer or 1
  local changed = 0

  for _, t in ipairs(get_all_texts()) do
    local desiredName, desiredSize = get_bookmark_style(t.text or "")
    local font = t.font or {}
    if t.page and parse_bookmark(t.text or "") and
        (font.name ~= desiredName or tonumber(font.size) ~= desiredSize
         or tonumber(t.color) ~= BOOKMARK_COLOR) then
      app.setCurrentPage(t.page)
      set_current_layer_compat(t.layer or 1)
      local ref = resolve_bookmark_element({
        page = t.page, layer = t.layer, name = t.text, ref = t.ref,
        x = t.x, y = t.y
      })
      if ref then
        app.clearSelection()
        app.addToSelection({ref})
        local selected = app.getTexts("selection")
        local old = selected and selected[1]
        if old and old.text == t.text then
          local refs = app.addTexts({texts = {{
            text = old.text, x = old.x, y = old.y, color = BOOKMARK_COLOR,
            wrap = old.wrap, font = {name = desiredName, size = desiredSize}
          }}})
          if refs and #refs > 0 then
            app.clearSelection()
            app.addToSelection({ref})
            app.activateAction("delete")
            changed = changed + 1
          end
        end
      end
    end
  end

  app.clearSelection()
  app.setCurrentPage(originalPage)
  set_current_layer_compat(originalLayer)
  if changed > 0 then
    app.refreshPage()
    save_document_silently()
  end
  app.openDialog(changed .. " existing bookmark(s) restyled.", {"OK"}, "")
end

function search_bookmark(mode)
  local allTexts = get_all_texts()
  if not allTexts then return end

  local bookmarkPages = {}
  for _, t in ipairs(allTexts) do
    if parse_bookmark(t.text or "") and t.page then
      bookmarkPages[t.page] = true
    end
  end

  local structure = app.getDocumentStructure()
  local numPages = #structure.pages
  local page = structure.currentPage

  for _ = 1, numPages do
    page = page + mode
    if page > numPages then page = 1 end
    if page < 1 then page = numPages end
    
    if bookmarkPages[page] then
      app.clearSelection()
      app.setCurrentPage(page)
      app.scrollToPage(page)
      return
    end
  end

  app.openDialog("No bookmark found.", {"Ok"}, "")
end

function dialog_new_bookmark()
  return new_bookmark()
end

function delete_bookmark(page, layer, elementRef)
  if not elementRef then return end
  app.setCurrentPage(page)
  set_current_layer_compat(layer or 1)
  app.clearSelection()
  app.addToSelection({elementRef})
  app.activateAction("delete")
  app.clearSelection()
  app.refreshPage()

  -- Sync UI deletion to disk
  save_document_silently()
end

function rename_bookmark(bookmark, label)
  label = (label or ""):match("^%s*(.-)%s*$")
  if label == "" then return false, "Enter a bookmark name." end
  local prefix, content = parse_bookmark(label)
  if prefix then
    label = content:match("^%s*(.-)%s*$")
    if label == "" then return false, "Enter a bookmark name." end
  else
    prefix = parse_bookmark(bookmark.name or "") or "*"
  end
  local new_text = prefix .. " " .. label
  if new_text == bookmark.name then return true end

  app.setCurrentPage(bookmark.page)
  set_current_layer_compat(bookmark.layer or 1)
  local ref = resolve_bookmark_element(bookmark)
  if not ref then return false, "Bookmark not found in the current document." end
  app.clearSelection()
  app.addToSelection({ref})
  local selected = app.getTexts("selection")
  local old = selected and selected[1]
  if not old then return false, "Bookmark not found in the current document." end

  local font_name, font_size = get_bookmark_style(new_text)
  local refs = app.addTexts({texts = {{
    text = new_text, x = old.x, y = old.y, color = old.color,
    wrap = old.wrap, font = {name = font_name, size = font_size}
  }}})
  if not refs or #refs == 0 then return false, "Could not rename bookmark." end
  app.clearSelection()
  app.addToSelection({ref})
  app.activateAction("delete")
  app.clearSelection()
  app.refreshPage()
  save_document_silently()
  return true
end

function view_bookmarks()
  local ok, err = pcall(bookmarks_ui.open)
  if not ok then
    app.openDialog("Could not open bookmarks.\n\n" .. tostring(err), {"OK"}, "", true)
  end
end

function export()
  local sep = package.config:sub(1,1)
  local pdftkOk = pcall(os.execute, "pdftk --version")
  if sep == "\\" then
    -- On Windows, pdftk is generally not available and the command-line based
    -- PDF bookmark injection is not supported.
    return app.openDialog("Export with bookmarks currently requires the `pdftk` tool, which was not found.", {"OK"}, "", true)
  end
  if not pdftkOk then return app.openDialog("pdftk is missing.", {"OK"}, "") end

  local structure = app.getDocumentStructure()
  local defaultName = (structure.xoppFilename and structure.xoppFilename:match("(.+)%..+$") or DEFAULT_EXPORT_PATH) .. "_export.pdf"
  local path = app.saveAs(defaultName)
  if not path then return end

  local tempData = os.tmpname()
  local tempPdf = tempData .. "_1337__.pdf"

  app.export({outputFile = tempPdf})
  os.execute("pdftk \"" .. tempPdf .. "\" dump_data output \"" .. tempData .. "\"")

  local bookmarks = {}
  local allTexts = get_all_texts()
  
  for _, t in ipairs(allTexts) do
    if parse_bookmark(t.text or "") and t.page then
      table.insert(bookmarks, { page = t.page, name = utf8_to_html(t.text), y = t.y or 0 })
    end
  end
  
  table.sort(bookmarks, function(a, b) return a.page == b.page and a.y < b.y or a.page < b.page end)
  
  local file = io.open(tempData,"a+")
  for _, b in ipairs(bookmarks) do
    file:write("BookmarkBegin\nBookmarkTitle: " .. b.name .. "\nBookmarkLevel: 1\nBookmarkPageNumber: " .. b.page .. "\n")
  end
  file:close()

  os.execute("pdftk \"" .. tempPdf .. "\" update_info \"" .. tempData .. "\" output \"" .. path .."\"")
  os.remove(tempData)
  os.remove(tempPdf)
end
