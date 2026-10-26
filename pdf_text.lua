-- Read text from the PDF used as a Xournal++ page background. Xournal++'s
-- app.getTexts() reports annotation text boxes, not text printed in the PDF.
local M = {}
local cached_path, cached_document, cached_outline

local function absolute_pdf_path(structure, path)
  if path:match("^[/\\]") or path:match("^[A-Za-z]:[/\\]") then return path end
  local xopp = structure.xoppFilename or ""
  local directory = xopp:match("^(.*[/\\])")
  return directory and (directory .. path) or path
end

local function pdf_location(structure, page_number)
  local path = structure and structure.pdfBackgroundFilename
  local page = structure and structure.pages and structure.pages[page_number]
  local pdf_page = page and tonumber(page.pdfBackgroundPageNo)
  if not path or path == "" or not pdf_page or pdf_page < 1 then return nil end
  return absolute_pdf_path(structure, path), pdf_page
end

local function document_for(path)
  local gi = require("LuaGObject")
  local Poppler = gi.require("Poppler", "0.18")
  if path ~= cached_path then
    local Gio = gi.require("Gio", "2.0")
    cached_path = path
    cached_document = Poppler.Document.new_from_file(
      Gio.File.new_for_path(path):get_uri(), nil)
    cached_outline = nil
  end
  return cached_document, Poppler
end

function M.get_page_text(structure, page_number)
  local path, pdf_page = pdf_location(structure, page_number)
  if not path then return nil end
  local ok, result = pcall(function()
    local document = document_for(path)
    if not document then return nil end
    local pdf_page_object = document:get_page(pdf_page - 1)
    return pdf_page_object and pdf_page_object:get_text() or nil
  end)
  if ok and type(result) == "string" and result ~= "" then return result end
  return nil
end

local function outline_entries(document, Poppler)
  local entries = {}
  local function walk(iter, depth)
    if not iter or depth > 32 then return end
    repeat
      local action = iter:get_action()
      if action and action.goto_dest then
        local dest = action.goto_dest.dest
        if dest and dest.named_dest then
          dest = document:find_dest(dest.named_dest) or dest
        end
        local title = action.any and action.any.title
        if dest and dest.page_num and title and title ~= "" then
          entries[#entries + 1] = {
            page = tonumber(dest.page_num), title = title, depth = depth
          }
        end
      end
      walk(iter:get_child(), depth + 1)
    until not iter:next()
  end
  walk(Poppler.IndexIter.new(document), 0)
  return entries
end

function M.get_section_title(structure, page_number)
  local path, pdf_page = pdf_location(structure, page_number)
  if not path then return nil end
  local ok, title = pcall(function()
    local document, Poppler = document_for(path)
    if not document then return nil end
    if not cached_outline then
      cached_outline = outline_entries(document, Poppler)
    end
    local best, best_page, best_depth = nil, 0, -1
    for _, entry in ipairs(cached_outline) do
      if entry.page and entry.page <= pdf_page and
          (entry.page > best_page or
            (entry.page == best_page and entry.depth > best_depth)) then
        best, best_page, best_depth = entry.title, entry.page, entry.depth
      end
    end
    return best
  end)
  return ok and title or nil
end

return M
