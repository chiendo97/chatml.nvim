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
}

---Convert JSON string of chat completion request to markdown
---@param json_str string JSON string of chat completion request
---@return string markdown Markdown string of chat completion request
M.json_to_md = function(json_str)
  -- Parse JSON string
  local ok, data = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })
  if not ok then
    error("Invalid JSON string")
  end
  if data == nil then
    error("Parsed (json) data is nil")
  end

  -- Validate messages key exists
  if not data.messages then
    error("Messages key not found in JSON")
  end

  -- Validate model key exists
  if not data.model then
    error("Model key not found in JSON")
  end

  -- Validate each message: check type, role, and content
  for _, msg in ipairs(data.messages) do
    if type(msg) ~= "table" or not msg.role then
      error("Each message must be a table with a 'role' key")
    end

    if not VALID_ROLES[msg.role] then
      error("Invalid role: " .. tostring(msg.role))
    end

    if msg.content == nil then
      error("Each message must have 'content'")
    end
  end

  -- Extract metadata (all keys except messages and functions)
  local metadata = {}
  for key, value in pairs(data) do
    if key ~= "messages" and key ~= "functions" then
      metadata[key] = value
    end
  end
  -- Trim leading/trailing whitespace from YAML metadata
  local metadata_str = yaml.encode(metadata):gsub("^%s+", ""):gsub("%s+$", "")

  -- Build markdown output
  local parts = { "---\n" .. metadata_str .. "\n---\n" }

  for _, msg in ipairs(data.messages) do
    local msg_parts = { "\n# " .. msg.role .. "\n" }

    -- Add tool_calls if present (## tool_call: func (id=...) ```json...)
    if msg.tool_calls and #msg.tool_calls > 0 then
      for _, tool_call in ipairs(msg.tool_calls) do
        table.insert(msg_parts, "\n## tool_call: " .. tool_call["function"].name .. " (id=" .. tool_call.id .. ")\n\n")
        table.insert(msg_parts, "```json\n" .. tool_call["function"].arguments .. "\n```\n")
      end
    end

    -- Add tool_call_id for tool role messages (## tool: name (id=...) ```json...)
    if msg.role == "tool" and msg.tool_call_id then
      table.insert(msg_parts, "\n## tool: " .. (msg.name or "response") .. " (id=" .. msg.tool_call_id .. ")\n\n")
      table.insert(msg_parts, "```json\n" .. msg.content .. "\n```\n")
    elseif msg.content then
      -- Add content for regular messages
      table.insert(msg_parts, "\n" .. msg.content .. "\n")
    end

    table.insert(parts, table.concat(msg_parts))
  end

  -- Trim trailing whitespace from entire markdown output
  return table.concat(parts):gsub("%s+$", "")
end

---Convert markdown string of chat completion request to JSON
---@param md_str string Markdown string of chat completion request
---@return string json JSON string of chat completion request
M.md_to_json = function(md_str)
  -- Parse YAML front matter: Extract metadata between ---\n...\n---
  -- Pattern: ^---\n(.*)\n---(.*)$ - captures front matter and remaining content
  local front_matter, content = md_str:match("^%-%-%-\n(.-)\n%-%-%-(.*)$")
  if not front_matter or #front_matter == 0 then
    error("Cannot parse front matter string")
  end

  local ok, config = pcall(yaml.decode, front_matter)
  if not ok then
    error("Cannot parse front matter YAML")
  end

  if config == nil then
    error("Front matter config is nil")
  end

  if type(config) ~= "table" then
    error("Parsed front matter is not a table")
  end

  if not config.model then
    error("Model key not found in front matter")
  end

  if #content == 0 then
    error("Content after front matter is empty")
  end

  -- Extract messages from markdown content
  local messages = {}
  -- Find message blocks by looking for \n# role headers
  -- Parse each message by finding content between headers
  local pos = 1

  while pos <= #content do
    local start, end_pos, role = content:find("# (%w+)\n\n", pos)
    if not start then
      break
    end

    if not VALID_ROLES[role] then
      error("Invalid role: " .. role)
    end

    -- Find the start of the next message (or end of content)
    local next_msg_pos = content:find("\n# ", end_pos + 1)
    local msg_end_pos = next_msg_pos or #content + 1

    -- Extract content between current header and next message
    -- Extracts the substring from `content` starting right after `end_pos` up to just before `msg_end_pos`,
    -- then trims any leading and trailing whitespace from this substring.
    local content_trim = content:sub(end_pos + 1, msg_end_pos - 1):gsub("^%s+", ""):gsub("%s+$", "")

    -- Parse a single message from markdown content
    ---@type ChatMLMessage
    local msg = { role = role }

    -- Process file includes: @path pattern (@ at start of line)
    -- Pattern: (\n\s*@([^\n]+)) - finds lines starting with @ and captures the path
    local search_content = "\n" .. content_trim
    for file_path in search_content:gmatch("\n%s*@([^\n]+)") do
      file_path = file_path:gsub("^%s+", ""):gsub("%s+$", "")

      local file = io.open(file_path, "r")
      local file_content
      if not file then
        vim.notify("Error reading file: " .. file_path .. " - Cannot open file: " .. file_path, vim.log.levels.WARN)
        file_content = "Error: Cannot open file: " .. file_path
      else
        file_content = file:read("*all")
        file:close()
        if not file_content then
          vim.notify(
            "Error reading file: " .. file_path .. " - Cannot read file content: " .. file_path,
            vim.log.levels.WARN
          )
          file_content = "Error: Cannot read file content: " .. file_path
        end
      end

      if file_content then
        content_trim = string.format("%s\n\n```%s\n%s\n```", content_trim, file_path, file_content)
      end
    end

    -- Parse tool_call_id: extract tool_call_id from ## tool: name (id=...) format (any role)
    -- Pattern: ## tool: func (id=...) ```json\n(content)\n```
    -- Extracts tool name, call ID, and JSON response content
    local _, tool_call_id, tool_content =
      content_trim:match("## tool:%s*(%S+)%s*%(%s*id%s*=%s*([^%)]+)%)%s*```json\n(.-)\n```")
    if tool_call_id then
      msg.tool_call_id = tool_call_id
      msg.content = tool_content or ""
      -- Remove the tool block from content
      content_trim = content_trim:gsub("## tool:%s*%S+%s*%(%s*id%s*=%s*[^%)]+%)%s*```json\n.-\n```%s*", "")
      content_trim = content_trim:gsub("^%s+", ""):gsub("%s+$", "")
    end

    -- Parse tool_calls blocks: ## tool_call: func (id=...) ```json...``` (any role)
    local tool_calls = {}
    -- Pattern: ## tool_call: func (id=...) ```json\n(args)```
    -- Captures function name, call ID, and JSON arguments
    local pattern_tool = "## tool_call:%s*(%S+)%s*%(%s*id%s*=%s*([^%)]+)%)%s*```json\n(.-)```"
    for func, id, args in content_trim:gmatch(pattern_tool) do
      table.insert(tool_calls, {
        id = id,
        type = "function",
        ["function"] = {
          name = func,
          arguments = args,
        },
      })
    end

    if #tool_calls > 0 then
      msg.tool_calls = tool_calls
      -- Remove all matched tool_call blocks from content
      -- Pattern: \n?## tool_call: func (id=...) ```json\n...\n``` with optional trailing space
      content_trim = content_trim:gsub("\n?## tool_call:%s*%S+%s*%(%s*id%s*=%s*[^%)]+%)%s*```json\n.-```%s*", "")
      -- Trim leading/trailing whitespace after removal
      content_trim = content_trim:gsub("^%s+", ""):gsub("%s+$", "")
    end

    -- For any message, use the trimmed content as-is if present
    if #content_trim > 0 then
      vim.print(content_trim)
      msg.content = content_trim
    end

    table.insert(messages, msg)

    pos = next_msg_pos or #content + 1
  end

  if #messages == 0 then
    error("No messages found")
  end

  config.messages = messages

  local ok_encode, json_str = pcall(vim.json.encode, config)
  if not ok_encode then
    error("Cannot encode table to json string")
  end

  return json_str
end

-- Buffer operations (external dependencies)

---Convert JSON buffer to markdown buffer using json_to_md
---@param in_buf number Input JSON buffer number
---@param out_buf number? Output markdown buffer number
---@return number? out_buf Output markdown buffer number
M.json_buf_to_md_buf = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "json" then
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
    error("Generated md_str is nil")
  end
end

---Convert markdown file to JSON string using md_to_json
---@param file_path string Path to the input markdown file
---@return string|nil json_str JSON string representation of the markdown content, or nil on error
M.md_file_to_json_str = function(file_path)
  local fd = io.open(file_path, "r")
  if not fd then
    error("Cannot open file: " .. file_path)
  end
  local md_str = fd:read("*a")
  fd:close()
  if not md_str then
    error("Failed to read markdown file content")
  end
  return M.md_to_json(md_str)
end

return M
