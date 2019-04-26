local linux = true
local BREAKLINE = linux and "\n" or "\n\r"
local REFERENCE_PATTERN = "(ref{%w+})"  -- TODO: optional pages
-- TODO: alphabetical order mode
-- TODO: find out the correct terminology (what is reference, what is citation?)

local function write_to_file (filepath, ...)
  --[[
  Create a file located at filepath and write in it the strings provided as the remaining arguments.
  (If such a file does already exist, rewrite it.)

  Args:
     filepath (string): either an absolute filepath or a path relative to the module directory

  ]]
  local file = assert(io.open(filepath, "w"))
  for _, s in ipairs{...} do
    file:write(s)
  end
  file:close()
end


local function process_bibfile (entry_callback, bibliography_filepath)
  --[[
  Execute the bibliography file running the entry callback with each entry.

  The bibliography file is expected to be a text file consisting of a sequence terms each of which
  is a lua code that calls the function named 'entry' on a table literal, i.e. something like
  
    entry{authors={'Erik Green', 'Alfred Gray'}, title='Journey to the South', year=2032}.

  The callback is expected to process those tables, and presumably to save the results into some external data structure.

  Args:
      entry_callback      (function): a function that accepts a single argument of type 'table'
      bibliography_filepath (string): a filepath to a text file containing the bibliography data

  ]]
  assert(loadfile(bibliography_filepath, "t", {entry=entry_callback}))()
end


local function process_text (text, formatter, code2entry, second_run)
  --[[
  The main function to process a text. It scans the text for reference codes, substitues the appropriate references for the reference codes,
  and returns the modified text and the sequence of entries as they first appeared in the text. (The entries are also embellished by an index
  that signalizes that the default reference was not unique. This is needed to construct an appropriate bibliography.)

  Args:
      text               (string): The text containing the reference codes.
      formatter        (function): A function that creates a reference from an entry object (thus it's type is: table -> string).
      code2entry          (table): A table mapping from reference codes to entry objects which contain all the information about the references.
      second_run (boolean or nil): A flag signalling that we are processing the text a second time. This is sometimes needed, because in advance
                                   we cannot know if the references will be unique. Thus we collect this information during the first time and
                                   record it in the entries. Afterwards we rerun the process (with the adjusted entries) if needed.

  Returns:
      string: The original text but with the appropriate references substituted for the reference codes.
      table: A sequence of the entries (embellished with information about the uniqueness of the references) in the order in which they first
             have been reffered to in the text. 
  ]]
  local code2reference = {}  -- a table [a code in the text (e.g. 'ref{john on pollution}')] => [a reference in the text (e.g. '(Black J., 2007)')]
  local index2entry = {}  -- a sequence of entries ordered by their first appearances in the text (default ordering of the bibliography)
  local reference_counters = {}  -- we need this to check if two different codes map to a same reference
  local ambivalent_references = false  -- if any two codes map to a same reference, we set this to true

  -- define the function to run with gsub
  local function reference_maker (rawcode)
    local code = string.sub(rawcode, 5, -2) -- rawcode looks like "ref{<code>}"
    local reference = code2reference[code]
    if reference then
      -- we have already cited this source
      return reference
    end
    -- if we got here, it is the first time the code has been used in the text
    local entry = assert(code2entry[code], "code not in bibliography: " .. tostring(code))
    reference = formatter(entry)
    -- save the reference into code2reference so we know it has already been cited
    code2reference[code] = reference
    -- put the entry in the list of entries that we use to build the bibliography
    index2entry[#index2entry + 1] = entry

    -- we also need to check if this reference has been unique so far
    local counter = reference_counters[reference]
    if not counter then
      reference_counters[reference] = entry  -- first time we save the entry itself (we will later need to access it if its reference is not unique)
    elseif type(counter) == "table" then  -- the first duplicit reference; the current entry has the same reference as the entry saved as 'counter'
      counter._id = 0  -- 'counter' points to the entry with (the reference of) which the current entry collides
      entry._id = 1  -- the current entry is thus the second entry with the same reference; we start indexing from 0, so we index it with 1
      reference_counters[reference] = 2  -- so far there have been two entries mapping to the reference 'reference'
      
      ambivalent_references = true
    else  -- the third or later entry mapping to the same reference
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
    return process_text(text, formatter, code2entry, true)
  end
end

local function make_reader (format_function)
  --[[
  Make a reader function that accepts an entry, modifies it, and extracts its code and index (if any).

  Args:
      format_function (function): a function [entry] => [bibliography reference]

  Returns:
      code  (string): an in-the-text code that identifies the cited work
      index (number): an optional number that describes the ordering of the resulting bibliography in some cases
      entry  (table): a modified entry (we add to it a function that returns a formatted entry to be added to bibliography)
  ]]
  return function (entry)
           local code = entry.code
           local index = entry.index
	   -- we cannot create the bibstring (the text describing the entry in the bibliography), because the does not contain all the relevant
	   -- information yet (we will need to see if the bibstrings will unique and modify the entries if not)
           entry.to_bibstring = function (self) return format_function(self) end
           return code, index, entry
         end
end


local function make_callback_for_codes (formatter, code2entry)
  --[[
  Return a function that accepts an entry, processes it and updates the code2entry table.

  Args:
      formatter (function): a function that accepts an entry and return a string that represents the entry in the bibliography
      code2entry   (table): a table mapping [in-the-text code] => [entry object] that will be updated by the returned callback

  Returns:
      function: a function that accepts the entries (tables), processes them and updates the code2entry table

  ]]
  local reader = make_reader(formatter)
  return function (entry)
           local code, index, processed_entry = reader(entry)
           assert(not code2entry[code], "duplicit code: " .. tostring(code))
           code2entry[code] = processed_entry
         end
end

local function make_callback_for_indices (formatter, explicit_indices_table, automatic_indices_table)
  --[[
  Create a function that will be used to process a bibliography file into a bibliography.

  In this case we basically just format all the entries in the bibliography file into a suitable text representation
  and order (and filter) them. If some indices are defined in the entries of the bibliography file (i.e. some entry tables
  contain an integer value if 'index' attribute) only those entries will enter the final bibliography and will be order
  according tot he values of those indices.

  Args:
      formatter (function): a function to create a text representation of a bibliography entry (it's type is table -> string)
      explicit_indices_table (table): an empty table to be filled with the text representation of the bibliography entries that contain indices
      automatic_indices_table (table): an empty table to be filled with the text representation of all the bibliography entries in the order
                                       in which they appear in the bibliography file

  Returns:
      function: a function to process the entries (it has type table -> nil)

  ]]
  local reader = make_reader(formatter)
  return function (entry)
           local code, index, processed_entry = reader(entry)
           assert(not explicit_indices_table[index], "duplicit index: " .. tostring(index))
           -- we directly save the text representation
	   local text_repr = processed_entry:to_bibstring()
           if index then
             explicit_indices_table[index] = text_repr
           end
           automatic_indices_table[#automatic_indices_table + 1] = text_repr
         end
end


local function process_bibliography_with_text (text, text_formatter, bibliography_filepath, bib_formatter)
  --[[
  Return a text with appropriate references and the bibliography.

  Args:
      text                  (string): a text containing the reference codes
      text_formatter      (function): a function to format an entry into an in-the-text reference
      bibliography_filepath (string): a filepath to the bibliography file
      bib_formatter       (function): a function to format an entry into a bibliography text representation

  Returns:
      string: a processed text containing the appriopriate references substitued for the reference codes
      string: a bibliography

  ]]
  -- we first create a table code -> entry
  local code2entry = {}
  -- define the entry callback
  local entry_callback = make_callback_for_codes(bib_formatter, code2entry)
  process_bibfile(entry_callback, bibliography_filepath)
  -- the table code2entry should be filled already
  local processed_text, index2entry = process_text(text, text_formatter, code2entry)
  local buffer = {}
  for _, entry in ipairs(index2entry) do
    buffer[#buffer + 1] = entry:to_bibstring()
  end
  return processed_text .. BREAKLINE, table.concat(buffer, BREAKLINE) .. BREAKLINE
end


local function process_bibliography_without_text(bibliography_filepath, bib_formatter)
  --[[
  Return a formatted bibliography from a bibliography file.

  Args:
      bibliography_filepath (string): a filepath to the bibliography file
      bib_formatter (function): a function to format a bibliography file entry into its bibliography representation

  Returns:
      string: a formatted bibliography

  ]]
  -- First create explicit and automatic indices tables
  local explicit_list = {}
  local automatic_list = {}
  -- define the entry callback
  local entry_callback = make_callback_for_indices(bib_formatter, explicit_list, automatic_list)
  process_bibfile(entry_callback, bibliography_filepath)

  -- choose which of the lists to use
  if #explicit_list > 0 then
    -- use manually defined indices if there were any
    return table.concat(explicit_list, BREAKLINE) .. BREAKLINE
  else
    --- otherwise we will format the whole bibliography file
    return table.concat(automatic_list, BREAKLINE) .. BREAKLINE
  end
end


local function process_bibliography (text, text_formatter, bibliography_filepath, bib_formatter, output_filepath)
  --[[
  The interface function that dispatches to an appropriate specialized function depending on the provided arguments.

  Args:
      text (string): the original text containing the reference codes
      text_formatter (function): a function that creates an in-the-text reference from an entry (type: table -> string)
      bibliography_filepath (string): a filepath to the file containing the bibliography entries
      bib_formatter (function): a function that creates a bibliography reference from an entry (type: table -> string)
      output_filepath (string): a filepath where to write the resulting text

  ]]
  if text then
    local processed_text, processed_bibliography = process_bibliography_with_text(text, text_formatter, bibliography_filepath, bib_formatter)
    write_to_file(output_filepath, processed_text, processed_bibliography)
  else
    local processed_bibliography = process_bibliography_without_text(bibliography_filepath, bib_formatter)
    write_to_file(output_filepath, processed_bibliography)
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
