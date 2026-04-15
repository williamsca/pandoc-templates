-- blog-filter.lua
-- Pandoc Lua filter to convert paper.md into a Jekyll blog post with Tufte sidenotes.
-- Runs citeproc internally with Chicago full-note style so citations render as
-- full bibliographic entries in the sidenotes.

local sidenote_counter = 0

local function make_sidenote(content)
  local n = sidenote_counter
  sidenote_counter = sidenote_counter + 1
  local html = string.format(
    '<label for="sn-%d" class="margin-toggle sidenote-number"></label>' ..
    '<input type="checkbox" id="sn-%d" class="margin-toggle"/>' ..
    '<span class="sidenote">%s</span>',
    n, n, content
  )
  return pandoc.RawInline('html', html)
end

-- Extract the full text from a Cite element. With note-style CSL, the Cite
-- wraps a Note containing the bibliographic entry; we flatten that here.
local function stringify_cite(cite)
  for _, inline in ipairs(cite.content) do
    if inline.t == 'Note' then
      -- The Note inside the Cite has the full reference text
      return pandoc.utils.stringify(inline.content)
    end
  end
  return pandoc.utils.stringify(cite.content)
end

-- Stringify inlines, resolving nested Cite elements and already-processed
-- sidenote RawInlines to their plain text content.
local function stringify_with_cites(inlines)
  local parts = {}
  for _, el in ipairs(inlines) do
    if el.t == 'Cite' then
      table.insert(parts, stringify_cite(el))
    elseif el.t == 'RawInline' and el.format == 'html'
      and el.text:match('class="sidenote"') then
      -- Extract text from an already-processed sidenote span
      local sn_text = el.text:match('<span class="sidenote">(.-)</span>')
      if sn_text then
        table.insert(parts, sn_text)
      end
    else
      table.insert(parts, pandoc.utils.stringify(el))
    end
  end
  return table.concat(parts)
end

-- Convert footnotes (from [^n] syntax) to sidenotes.
-- Any Cite elements inside are resolved to their full text inline.
local function process_note(note)
  local inlines = pandoc.List()
  for _, block in ipairs(note.content) do
    if block.t == 'Para' or block.t == 'Plain' then
      if #inlines > 0 then
        inlines:insert(pandoc.Space())
      end
      inlines:extend(block.content)
    end
  end
  local content = stringify_with_cites(inlines)
  return make_sidenote(content)
end

-- Convert Cite elements to sidenotes.
-- AuthorInText citations (e.g. @key argue) keep the author inline and put
-- the rest in a sidenote. NormalCitation puts everything in a sidenote.
local function process_cite(el)
  local mode = el.citations[1] and el.citations[1].mode

  if mode == 'AuthorInText' then
    -- Author names are inline text; the Note child has the rest of the reference.
    local result = pandoc.List()
    for _, inline in ipairs(el.content) do
      if inline.t == 'Note' then
        result:insert(make_sidenote(pandoc.utils.stringify(inline.content)))
      elseif inline.t == 'RawInline' and inline.format == 'html'
        and inline.text:match('class="sidenote"') then
        result:insert(inline)
      else
        result:insert(inline)
      end
    end
    return result
  end

  -- NormalCitation: check if a child was already converted to a sidenote
  for _, inline in ipairs(el.content) do
    if inline.t == 'RawInline' and inline.format == 'html'
      and inline.text:match('class="sidenote"') then
      return inline
    end
  end
  local text = stringify_cite(el)
  if text ~= '' then
    return make_sidenote(text)
  end
end

local function process_rawinline(el)
  if el.format == 'latex' or el.format == 'tex' then
    if el.text:match('\\ref{.-}') then
      return pandoc.Str('')
    end
    local fn_content = el.text:match('\\footnote{(.*)}')
    if fn_content then
      return make_sidenote(fn_content)
    end
  end
end

local function process_rawblock(el)
  if el.format ~= 'latex' and el.format ~= 'tex' then
    return nil
  end

  local text = el.text
  if not text:match('\\begin{figure}') then
    return nil
  end

  local caption = text:match('\\caption{(.-)}') or ''
  caption = caption:gsub('\\label{.-}', ''):gsub('^%s+', ''):gsub('%s+$', '')

  local img_path = text:match('\\includegraphics%[?[^%]]*%]?{(.-)}')
  if not img_path then return nil end

  local basename = img_path:match('([^/]+)%.pdf$') or img_path:match('([^/]+)%.png$')
  if not basename then return nil end
  local blog_path = '/assets/images/' .. basename .. '.png'

  local notes = text:match('\\begin{flushleft}(.-)\\end{flushleft}')
  local note_text = ''
  if notes then
    note_text = notes:gsub('\\begin{footnotesize}', '')
    note_text = note_text:gsub('\\end{footnotesize}', '')
    note_text = note_text:gsub('\\emph{%s*(.-)%s*}', '*%1*')
    note_text = note_text:gsub('\\\\', '')
    note_text = note_text:gsub('\n%s*\n', '\n')
    note_text = note_text:gsub('^%s+', ''):gsub('%s+$', '')
  end

  local blocks = pandoc.List()
  blocks:insert(pandoc.Para({pandoc.Image({pandoc.Str(caption)}, blog_path)}))
  if note_text ~= '' then
    local note_doc = pandoc.read(note_text, 'markdown')
    blocks:extend(note_doc.blocks)
  end

  return blocks
end

-- Clean up "Figure \ref{}" patterns after \ref is eaten
local function clean_figure_refs(para)
  if para.t ~= 'Para' then return nil end

  local inlines = para.content
  local new_inlines = pandoc.List()
  local i = 1
  while i <= #inlines do
    local el = inlines[i]
    if el.t == 'Str' and (el.text == 'Figure' or el.text == 'Figures') then
      if i + 2 <= #inlines
        and inlines[i+1].t == 'Space'
        and inlines[i+2].t == 'Str' and inlines[i+2].text == '' then
        if i + 6 <= #inlines
          and inlines[i+3].t == 'Space'
          and inlines[i+4].t == 'Str' and inlines[i+4].text == 'and'
          and inlines[i+5].t == 'Space'
          and inlines[i+6].t == 'Str' and inlines[i+6].text == '' then
          new_inlines:insert(pandoc.Str('The'))
          new_inlines:insert(pandoc.Space())
          new_inlines:insert(pandoc.Str('figures'))
          new_inlines:insert(pandoc.Space())
          new_inlines:insert(pandoc.Str('above'))
          i = i + 7
        else
          new_inlines:insert(pandoc.Str('The'))
          new_inlines:insert(pandoc.Space())
          new_inlines:insert(pandoc.Str('figure'))
          new_inlines:insert(pandoc.Space())
          new_inlines:insert(pandoc.Str('above'))
          i = i + 3
        end
      else
        new_inlines:insert(el)
        i = i + 1
      end
    elseif el.t == 'Str' and el.text == '' then
      i = i + 1
    else
      new_inlines:insert(el)
      i = i + 1
    end
  end

  return pandoc.Para(new_inlines)
end

-- Fix sidenote placement: move sidenote markers after adjacent punctuation.
-- Pandoc produces [..., Space, Sidenote, Str(".")], we want [..., Str("."), Sidenote].
local function fix_sidenote_placement(para)
  if para.t ~= 'Para' then return nil end

  local inlines = para.content
  local new_inlines = pandoc.List()
  local i = 1
  while i <= #inlines do
    local el = inlines[i]
    if el.t == 'RawInline' and el.format == 'html'
      and el.text:match('class="sidenote"') then
      -- Look ahead: next element might be Str starting with punctuation
      if i + 1 <= #inlines and inlines[i+1].t == 'Str' then
        local next_text = inlines[i+1].text
        local punct = next_text:match('^([%.,:;%?!%)%]])')
        if punct then
          local remainder = next_text:sub(#punct + 1)
          -- Remove preceding space
          if #new_inlines > 0 and new_inlines[#new_inlines].t == 'Space' then
            new_inlines:remove(#new_inlines)
          end
          new_inlines:insert(pandoc.Str(punct))
          new_inlines:insert(el)
          if remainder ~= '' then
            new_inlines:insert(pandoc.Str(remainder))
          end
          i = i + 2
        else
          -- Remove preceding space before sidenote even without following punct
          if #new_inlines > 0 and new_inlines[#new_inlines].t == 'Space' then
            new_inlines:remove(#new_inlines)
          end
          new_inlines:insert(el)
          i = i + 1
        end
      else
        if #new_inlines > 0 and new_inlines[#new_inlines].t == 'Space' then
          new_inlines:remove(#new_inlines)
        end
        new_inlines:insert(el)
        i = i + 1
      end
    else
      new_inlines:insert(el)
      i = i + 1
    end
  end

  return pandoc.Para(new_inlines)
end

function Pandoc(doc)
  -- Override CSL to Chicago full-note for rich bibliographic sidenotes
  doc.meta['csl'] = pandoc.MetaInlines{pandoc.Str(
    '/usr/share/texlive/texmf-dist/tex/latex/citation-style-language/styles/chicago-fullnote-bibliography.csl'
  )}

  doc = pandoc.utils.citeproc(doc)

  local meta = doc.meta

  -- Process inlines in a single walk. Order matters:
  -- - Cite: standalone citations (which wrap a Note after citeproc)
  -- - Note: [^n] footnotes (which may contain Cite elements)
  -- By handling both in one walk, pandoc visits each element once at its
  -- natural nesting level. Cite is visited before its child Note, so we
  -- intercept the whole Cite and extract the Note text ourselves.
  doc = doc:walk({
    Cite = process_cite,
    Note = process_note,
    RawInline = process_rawinline,
    RawBlock = process_rawblock,
  })

  doc = doc:walk({ Para = clean_figure_refs })
  doc = doc:walk({ Para = fix_sidenote_placement })

  -- Remove References section
  local new_blocks = pandoc.List()
  local in_references = false
  for _, block in ipairs(doc.blocks) do
    if block.t == 'Header' then
      local text = pandoc.utils.stringify(block)
      if text == 'References' or text == 'Bibliography' then
        in_references = true
      else
        in_references = false
        new_blocks:insert(block)
      end
    elseif block.t == 'Div' and block.identifier == 'refs' then
      -- skip
    elseif not in_references then
      new_blocks:insert(block)
    end
  end

  -- Repo link
  new_blocks:insert(pandoc.HorizontalRule())
  local repo_link = pandoc.read(
    'Code and data for this essay are available on [GitHub](https://github.com/williamsca/manufactured-productivity).',
    'markdown'
  )
  new_blocks:extend(repo_link.blocks)

  -- Thanks in italics
  local thanks = meta.thanks
  if thanks then
    local thanks_str = pandoc.utils.stringify(thanks)
    new_blocks:insert(pandoc.Para({pandoc.Emph({pandoc.Str(thanks_str)})}))
  end

  doc.blocks = new_blocks
  return doc
end
