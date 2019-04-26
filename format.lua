local linux = true
local BREAKLINE = linux and "\n" or "\n\r"
local REFERENCE_PATTERN = "(ref{%w+})"  -- TODO: optional pages
-- TODO: alphabetical order mode
-- TODO: 1882a to bib


local function write_to_file (filename, ...)
  local file = assert(io.open(filename, "w"))
  for _, s in ipairs{...} do
    file:write(s)
  end
  file:close()
end

local function process_bibfile (entry_callback, bibliography_file)
  assert(loadfile(bibliography_file, "t", {entry=entry_callback}))()
end

local function process_text (text, formatter, code2entry, second_run)
  local code2reference = {}
  local index2entry = {}
  local reference_counters = {}  -- we need this to check if two different codes map to a same reference
  local ambivalent_references = false

  -- define the function to run with gsub
  local function reference_maker (rawcode)
    local code = string.sub(rawcode, 5, -2) -- rawcode looks like "ref{<code>}"
    local reference = code2reference[code]
    if reference then
      -- we have already cited this source
      return reference
    end
    -- if we get here, this is the first time the code has been used in the text
    local entry = assert(code2entry[code], "code not in bibliography: " .. tostring(code))
    reference = formatter(entry)
    -- save the reference into code2reference so we know it has already been cited
    code2reference[code] = reference
    -- put the entry in the lsit of entries that we use to build the bibliography
    index2entry[#index2entry + 1] = entry

    -- we also need to check if this reference has been unique so far
    local counter = reference_counters[reference]
    if not counter then
      reference_counters[reference] = entry  -- first time we save the entry itself (we will need to access it if its reference is not unique)
    elseif type(counter) == "table" then
      -- the first duplicit reference
      counter._id = 0 -- we will index entries mapping to a same reference starting from zero
      entry._id = 1
      reference_counters[reference] = 2

      ambivalent_references = true
    else
      entry._id = counter
      reference_counters[reference] = counter + 1
    end
    
    return reference
  end
  
  local processed_text = string.gsub(text, REFERENCE_PATTERN, reference_maker)
  if (not ambivalent_references) or second_run then
    return processed_text, index2entry
  else
    -- note that this time the entries in the table code2entry include the identifiers "_id"
    return process_text (text, formatter, code2entry, true)
  end
end  

local function make_reader (format_function)
  return function (entry)
           local code = entry.code
           local index = entry.index
           entry.text = format_function(entry)
           return code, index, entry
         end
end

local function make_callback_for_codes (reader, code2entry)
  return function (entry)
           local code, index, processed_entry = reader(entry)
           assert(not code2entry[code], "duplicit code: " .. tostring(code))
           code2entry[code] = processed_entry
         end
end

local function make_callback_for_indices (reader, explicit_indices_table, automatic_indices_table)
  return function (entry)
           local code, index, processed_entry = reader(entry)
           assert(not explicit_indices_table[index], "duplicit index: " .. tostring(index))
           -- we only need the text itself in this mode
           if index then
             explicit_indices_table[index] = processed_entry.text
           end
           automatic_indices_table[#automatic_indices_table + 1] = processed_entry.text
         end
end

local function process_bibliography_with_text (text, text_formatter, bibliography_file, bib_formatter)
  -- we first create a table code -> entry
  local code2entry = {}
  -- define the entry callback
  local entry_callback = make_callback_for_codes(make_reader(bib_formatter), code2entry)
  process_bibfile(entry_callback, bibliography_file)
  -- the table code2entry should be filled already
  local processed_text, index2entry = process_text(text, text_formatter, code2entry)
  local buffer = {}
  for _, entry in ipairs(index2entry) do
    buffer[#buffer + 1] = entry.text
  end
  return processed_text .. BREAKLINE, table.concat(buffer, BREAKLINE) .. BREAKLINE
end

local function process_bibliography_without_text(bibliography_file, bib_formatter)
  -- first create explicit and automatic indices tables
  local explicit_list = {}
  local automatic_list = {}
  -- define the entry callback
  local entry_callback = make_callback_for_indices(make_reader(bib_formatter), explicit_list, automatic_list)
  process_bibfile(entry_callback, bibliography_file)

  -- choose which of the lists to use
  if #explicit_list > 0 then
    -- use manually defined indices if there were any
    return table.concat(explicit_list, BREAKLINE) .. BREAKLINE
  else
    --- otherwise we will format the whole bibliography file
    return table.concat(automatic_list, BREAKLINE) .. BREAKLINE
  end
end

local function process_bibliography (text, text_formatter, bibliography_file, bib_formatter, output_file)
  if text then
    local processed_text, processed_bibliography = process_bibliography_with_text(text, text_formatter, bibliography_file, bib_formatter)
    write_to_file(output_file, processed_text, processed_bibliography)
  else
    local processed_bibliography = process_bibliography_without_text(bibliography_file, bib_formatter)
    write_to_file(output_file, processed_bibliography)
  end
  print("Done")
end


local function test_bib_formatter (entry)
  local year_suffix = entry._id and string.char(entry._id + string.byte("a")) or "" 
  return table.concat(entry.authors, ", ") .. ". " .. entry.title .. ". " .. entry.year .. year_suffix
end

local function test_ref_formatter (entry)
  local year_suffix = entry._id and string.char(entry._id + string.byte("a")) or "" 
  return table.concat(entry.authors, ", ") .. ": " .. entry.year .. year_suffix
end

local test_text = [[
We will quote our authors (ref{alexander})  here (ref{john1}) and here (ref{john3}).
]]
local output_file = "t.txt"
local bibfile = "bibdata.lua"
process_bibliography(test_text, test_ref_formatter, bibfile, test_bib_formatter, output_file)
