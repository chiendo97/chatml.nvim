local log = require("chatml.log")
local yaml = require("chatml.yaml")

---@class ChatMLParse
local M = {}

---Valid ChatML message roles
---@type table<string, boolean>
local VALID_ROLES = {
  assistant = true,
  developer = true,
  system = true,
  tool = true,
  user = true,
  ["function"] = true,
}

---Validate a single ChatML message
---@param msg any The message to validate
---@return boolean valid True if message is valid
---@return string? error Error message if invalid
local function validate_message(msg)
  if type(msg) ~= "table" or not msg.role then
    return false, "Each message must be a table with a 'role' key"
  end

  if not VALID_ROLES[msg.role] then
    return false, "Invalid role: " .. tostring(msg.role)
  end

  if msg.content == nil and msg.function_call == nil and not (msg.role == "function" and msg.name) then
    return false, "Each message must have 'content', or 'function_call', or 'name' (for role=function)"
  end

  return true
end

---Validate ChatML request structure
---@param data table The parsed JSON data
---@return boolean valid True if request is valid
---@return string? error Error message if invalid
local function validate_request(data)
  if not data.messages then
    return false, "Messages key not found in JSON"
  end

  if not data.model then
    return false, "Model key not found in JSON"
  end

  for _, msg in ipairs(data.messages) do
    local valid, err = validate_message(msg)
    if not valid then
      return false, err
    end
  end

  return true
end

---Extract metadata from request, excluding messages and functions
---@param data ChatMLRequest The request data
---@return table metadata The metadata without messages/functions
local function extract_metadata(data)
  local metadata = {}
  for key, value in pairs(data) do
    if key ~= "messages" and key ~= "functions" then
      metadata[key] = value
    end
  end
  return metadata
end

---Format a single message as markdown
---@param msg ChatMLMessage The message to format
---@return string markdown The formatted markdown string
local function format_message_as_markdown(msg)
  local parts = { "\n# " .. msg.role .. "\n" }

  -- Add function_call if present
  if msg.function_call then
    table.insert(parts, "\n### function_call: " .. tostring(msg.function_call.name) .. "\n\n")
    local args = (msg.function_call.arguments or ""):gsub("%s+$", "")
    table.insert(parts, "```json\n" .. args .. "\n```\n")
  end

  -- Add function name if present and role is "function"
  if msg.role == "function" and msg.name then
    table.insert(parts, "\n### function: " .. tostring(msg.name) .. "\n")
  end

  -- Add content if present
  if msg.content then
    table.insert(parts, "\n" .. msg.content .. "\n")
  end

  table.insert(parts, "\n---\n")
  return table.concat(parts)
end

---Parse JSON string into table
---@param json_str string JSON string to parse
---@return table? data Parsed data or nil on error
---@return string? error Error message if parsing failed
local function parse_json_string(json_str)
  local ok, data = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })
  if not ok then
    return nil, "Invalid JSON string"
  end
  if data == nil then
    return nil, "Parsed (json) data is nil"
  end
  return data
end

---Convert JSON string of chat completion request to markdown
---@param json_str string JSON string of chat completion request
---@return string? markdown Markdown string of chat completion request
---@return string? error Error message if conversion failed
M.json_to_md_pure = function(json_str)
  local data, parse_err = parse_json_string(json_str)
  if not data then
    return nil, parse_err
  end

  local valid, validation_err = validate_request(data)
  if not valid then
    return nil, validation_err
  end

  local metadata = extract_metadata(data)
  local metadata_str = yaml.encode(metadata):gsub("^%s+", ""):gsub("%s+$", "")

  local parts = { "---\n" .. metadata_str .. "\n---\n" }

  for _, msg in ipairs(data.messages) do
    table.insert(parts, format_message_as_markdown(msg))
  end

  return table.concat(parts):gsub("%s+$", ""), nil
end

---Convert JSON string of chat completion request to markdown (with error throwing)
---@param json_str string JSON string of chat completion request
---@return string markdown Markdown string of chat completion request
M.json_to_md = function(json_str)
  local result, err = M.json_to_md_pure(json_str)
  if not result then
    log.debug(err)
    error(err)
  end
  return result
end

---Parse markdown front matter
---@param md_str string Markdown string with front matter
---@return table? config Parsed front matter or nil on error
---@return string? content Content after front matter
---@return string? error Error message if parsing failed
local function parse_markdown_front_matter(md_str)
  local front_matter, content = md_str:match("^%-%-%-\n(.-)\n%-%-%-(.*)$")
  if not front_matter or #front_matter == 0 then
    return nil, nil, "Cannot parse Markdown string"
  end

  local ok, config = pcall(yaml.decode, front_matter)
  if not ok then
    return nil, nil, "Cannot parse front matter YAML"
  end

  if config == nil then
    return nil, nil, "Parsed (yaml) config is nil"
  end

  if type(config) ~= "table" then
    return nil, nil, "Parsed front matter is not a table"
  end

  if not config.model then
    return nil, nil, "Model key not found in front matter"
  end

  if #content == 0 then
    return nil, nil, "Content after front matter is empty"
  end

  return config, content
end

---Parse function call block from message content
---@param content string Message content
---@return string? func_name Function name
---@return string? func_args Function arguments
---@return string cleaned_content Content with function call block removed
local function parse_function_call_block(content)
  local func_call_name, func_call_args = content:match("### function_call:%s*(%S+)%s-```json\n(.-)```")

  if func_call_name and func_call_args then
    local cleaned_content = content
      :gsub("### function_call:%s*" .. vim.pesc(func_call_name) .. "%s-```json\n.-```%s*", "")
      :gsub("^%s+", "")
      :gsub("%s+$", "")
    return func_call_name, func_call_args, cleaned_content
  end

  return nil, nil, content
end

---Parse function name block for function role
---@param content string Message content
---@return string? func_name Function name
---@return string? rest_content Remaining content
local function parse_function_name_block(content)
  local func_name, rest_content = content:match("### function:%s*(%S+)%s*\n(.+)")
  if func_name then
    return func_name, rest_content and rest_content:gsub("^%s+", "") or ""
  end
  return nil, content
end

---Parse a single message from markdown content
---@param role string Message role
---@param msg_content string Message content
---@return ChatMLMessage message Parsed message
local function parse_message_from_markdown(role, msg_content)
  local msg = { role = role }
  local content_trim = msg_content:gsub("^%s+", ""):gsub("%s+$", "")

  local func_call_name, func_call_args, cleaned_content = parse_function_call_block(content_trim)

  if func_call_name and func_call_args then
    msg.function_call = {
      name = func_call_name,
      arguments = func_call_args,
    }
    if #cleaned_content > 0 then
      msg.content = cleaned_content
    end
  elseif role == "function" then
    local func_name, rest_content = parse_function_name_block(content_trim)
    if func_name then
      msg.name = func_name
      msg.content = rest_content
    else
      msg.content = content_trim
    end
  else
    msg.content = content_trim
  end

  return msg
end

---Extract messages from markdown content
---@param content string Markdown content after front matter
---@return ChatMLMessage[]? messages Extracted messages or nil on error
---@return string? error Error message if extraction failed
local function extract_messages_from_markdown(content)
  local messages = {}
  local pattern = "\n# (%w+)\n\n(.-)\n\n%-%-%-"

  for role, msg_content in content:gmatch(pattern) do
    if not VALID_ROLES[role] then
      return nil, "Invalid role: " .. role
    end
    table.insert(messages, parse_message_from_markdown(role, msg_content))
  end

  if #messages == 0 then
    return nil, "No messages found"
  end

  return messages
end

---Read file content and return it as string
---@param filepath string Path to the file to read
---@return string? content File content or nil if file cannot be read
---@return string? error Error message if file reading failed
local function read_file_content(filepath)
  local file = io.open(filepath, "r")
  if not file then
    return nil, "Cannot open file: " .. filepath
  end

  local content = file:read("*all")
  file:close()

  if not content then
    return nil, "Cannot read file content: " .. filepath
  end

  return content
end

---Parse file references from markdown content and create user messages
---@param content string Markdown content
---@return ChatMLMessage[] file_messages Array of user messages with file content
local function parse_file_references(content)
  local file_messages = {}

  -- Pattern to match #file:path lines
  for file_path in content:gmatch("\n?%-?%s*#file:([^\n]+)") do
    file_path = file_path:gsub("^%s+", ""):gsub("%s+$", "") -- trim whitespace

    local file_content, err = read_file_content(file_path)
    if file_content then
      local message_content = string.format("#file:%s\n````\n%s\n````", file_path, file_content)
      table.insert(file_messages, {
        role = "user",
        content = message_content,
      })
    else
      -- If file cannot be read, still create a message indicating the error
      err = err or "Unknown error"
      vim.notify("Error reading file: " .. file_path .. " - " .. err, vim.log.levels.WARN)

      local message_content = string.format("#file:%s\n````\nError: %s\n````", file_path, err)
      table.insert(file_messages, {
        role = "user",
        content = message_content,
      })
    end
  end

  return file_messages
end

---Convert markdown string to JSON (pure function)
---@param md_str string Markdown string of chat completion request
---@return string? json JSON string or nil on error
---@return string? error Error message if conversion failed
M.md_to_json_pure = function(md_str)
  local config, content, parse_err = parse_markdown_front_matter(md_str)
  if not config then
    return nil, parse_err
  end

  if content == nil then
    return nil, "Content is nil"
  end

  -- Parse file references first
  local file_messages = parse_file_references(content)

  local messages, extract_err = extract_messages_from_markdown(content)
  if not messages then
    return nil, extract_err
  end

  -- Combine file messages with regular messages
  local all_messages = {}
  for _, file_msg in ipairs(file_messages) do
    table.insert(all_messages, file_msg)
  end
  for _, msg in ipairs(messages) do
    table.insert(all_messages, msg)
  end

  config.messages = all_messages

  local json_str_ok, json_str = pcall(vim.json.encode, config)
  if not json_str_ok then
    return nil, "Cannot encode table to json string"
  end

  return json_str
end

---Convert markdown string of chat completion request to JSON (with error throwing)
---@param md_str string Markdown string of chat completion request
---@return string json JSON string of chat completion request
M.md_to_json = function(md_str)
  local result, err = M.md_to_json_pure(md_str)
  if not result then
    log.debug(err)
    error(err)
  end
  return result
end

-- Buffer operations (external dependencies)

---Convert JSON buffer to markdown buffer using json_to_md
---@param in_buf number Input JSON buffer number
---@param out_buf number? Output markdown buffer number
---@return number? out_buf Output markdown buffer number
M.json_buf_to_md_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "json" then
    log.debug("Buffer is not a JSON buffer")
    error("Buffer is not a JSON buffer")
  end
  local json_str = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n")
  local md_str = M.json_to_md(json_str)
  if md_str then
    out_buf = out_buf or vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = out_buf })
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, vim.split(md_str, "\n"))
    return out_buf
  else
    log.debug("Generated md_str is nil")
    error("Generated md_str is nil")
  end
end

---Convert markdown buffer to JSON buffer using md_to_json
---@param in_buf number Input markdown buffer number
---@param out_buf number? Output JSON buffer number
---@return number? out_buf Output JSON buffer number
M.md_buf_to_json_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "markdown" then
    log.debug("Buffer is not a markdown buffer")
    error("Buffer is not a markdown buffer")
  end
  local md_str = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n")
  local json_str = M.md_to_json(md_str)
  if json_str then
    out_buf = out_buf or vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "json", { buf = out_buf })
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, vim.split(json_str, "\n"))
    return out_buf
  else
    log.debug("Generated md_str is nil")
    error("Generated md_str is nil")
  end
end

return M
