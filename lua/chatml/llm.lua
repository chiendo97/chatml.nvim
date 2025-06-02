local log = require("chatml.log")
local parse = require("chatml.parse")
local ai = require("ai")
local hub = require("mcphub").get_hub_instance()

---@class ChatMLLLM
local M = {}

M.client = ai.Client:new()

---Get the last line, column and line count in the chat buffer
---@param buf integer The buffer number
---@return integer last_line Number of the last line
---@return integer last_column Number of columns in the last line
local function get_buffer_last_position(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local last_line = line_count - 1
  if last_line < 0 then
    return 0, 0
  end
  local last_line_content = vim.api.nvim_buf_get_lines(buf, -2, -1, false)
  if not last_line_content or #last_line_content == 0 then
    return last_line, 0
  end
  local last_column = #last_line_content[1]
  return last_line, last_column
end

---Format role header lines
---@param role string The message role
---@return string[] lines The formatted role header lines
local function format_role_header(role)
  return { "", "# " .. role, "", "" }
end

---Format function call lines
---@param func_name string Function name
---@param args string Function arguments
---@return string[] lines The formatted function call lines
local function format_function_call_lines(func_name, args)
  return {
    "### function_call: " .. func_name,
    "",
    "```json",
    args,
    "```",
    "",
  }
end

---Format function name lines for function role
---@param func_name string Function name
---@return string[] lines The formatted function name lines
local function format_function_name_lines(func_name)
  return {
    "### function: " .. func_name,
    "",
  }
end

---Split content into lines
---@param content string Content to split
---@return string[] lines The split content lines
local function split_content_to_lines(content)
  return vim.split(content, "\n", { plain = true, trimempty = false })
end

---Add tools to request
---@param request ChatMLRequest The chat completion request
---@param tools any[] Array of tools from hub
---@return ChatMLRequest request The modified request
local function add_tools_to_request(request, tools)
  request["functions"] = request["functions"] or {}

  for _, tool in ipairs(tools) do
    table.insert(request["functions"], {
      name = string.format("%s-%s", tool.server_name, tool.name),
      description = tool.description,
      parameters = tool.inputSchema,
    })
  end

  -- Clean up examples from parameters
  for _, func in ipairs(request["functions"]) do
    if func.parameters and func.parameters.properties then
      for _, param in pairs(func.parameters.properties) do
        param.examples = nil
      end
    end
  end

  return request
end

---Parse function name from tool call format
---@param func_call_name string Function call name in format "server-function"
---@return string? server_name Server name
---@return string? func_name Function name
local function parse_tool_name(func_call_name)
  return func_call_name:match("([^/]+)-([^/]+)")
end

---Parse function arguments from JSON string
---@param args_str string JSON string of arguments
---@return table args Parsed arguments table
local function parse_function_arguments(args_str)
  local decode_ok, decoded_args = pcall(vim.json.decode, args_str or "{}")
  if decode_ok and type(decoded_args) == "table" then
    return decoded_args
  end
  return {}
end

---Format tool call result as content
---@param response any Tool call response
---@param err? string Error message if tool call failed
---@return string content Formatted content string
local function format_tool_result(response, err)
  if err then
    return vim.json.encode({ error = "Tool call error: " .. err })
  end

  if response and response.result and response.result.content then
    local first_content = response.result.content[1]
    if first_content and first_content.text then
      return string.format("````json\n%s\n````", first_content.text)
    else
      return string.format("````json\n%s\n````", response.result.content)
    end
  end

  return "{}"
end

---Handle function call in last assistant message
---@param request ChatMLRequest The chat completion request
---@return ChatMLRequest request The modified request
---@return string? updated_md_str Updated markdown string if function was called
local function handle_last_function_call(request)
  local last_msg = request.messages[#request.messages]
  if not (last_msg and last_msg.role == "assistant" and last_msg.function_call) then
    return request, nil
  end

  local server_name, func_name = parse_tool_name(last_msg.function_call.name)
  local func_args = parse_function_arguments(last_msg.function_call.arguments)

  local response, err = hub:call_tool(server_name, func_name, func_args)
  local result_content = format_tool_result(response, err)

  if err then
    vim.notify("Tool call error: " .. err, vim.log.levels.ERROR)
  end

  table.insert(request.messages, {
    role = "function",
    name = string.format("%s-%s", server_name, func_name),
    content = result_content,
  })

  local updated_md_str = parse.json_to_md(vim.json.encode(request, { luanil = { object = true, array = true } }))
  return request, updated_md_str
end

---Prepare chat completion request from markdown buffer
---@param in_buf integer Input markdown buffer
---@return ChatMLRequest request Prepared request
---@return string md_str Final markdown string
local function prepare_chat_request(in_buf)
  local md_str = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n"):gsub("%s+$", "")
  local json_str = parse.md_to_json(md_str)
  local ok, request = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })

  if not ok or type(request) ~= "table" then
    log.error("Cannot parse JSON string into request", request)
    error("Cannot parse JSON string into request")
  end

  -- Add tools
  local tools = hub:get_tools()
  request = add_tools_to_request(request, tools)

  -- Handle function calls
  local updated_md_str
  request, updated_md_str = handle_last_function_call(request)

  return request, updated_md_str or md_str
end

-- Callback creators for external dependencies

---Create callback for non-streaming chat completion
---@param out_buf integer Output buffer
---@return function callback Callback function for chat completion
local function create_chat_completion_callback(out_buf)
  local last_role = ""

  return function(chat_completion_obj)
    local message = chat_completion_obj.choices[1].message
    local role = message.role

    if role ~= nil and role ~= "" and last_role ~= role then
      local role_lines = format_role_header(role)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, role_lines)
      last_role = role
    end

    if message.function_call then
      local func_name = message.function_call.name or ""
      local args = message.function_call.arguments or ""
      local func_lines = format_function_call_lines(func_name, args)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, func_lines)
    end

    if role == "function" and message.name then
      local func_name_lines = format_function_name_lines(message.name)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, func_name_lines)
    end

    if message.content and message.content ~= "" then
      local content_lines = split_content_to_lines(message.content)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, content_lines)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, { "" })
    end

    vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, { "---" })
  end
end

---Create callback for streaming chat completion
---@param out_buf integer Output buffer
---@return function callback Callback function for chat completion chunks
local function create_streaming_callback(out_buf)
  local state = {
    last_role = "",
    func_call_name = nil,
    func_call_args = "",
  }

  return function(chat_completion_chunk_obj)
    local choice = chat_completion_chunk_obj.choices[1]
    local delta = choice.delta

    local role = delta.role
    if role ~= nil and role ~= "" and state.last_role ~= role then
      local role_lines = format_role_header(role)
      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, role_lines)
      state.last_role = role
    end

    if delta.function_call then
      if delta.function_call.name then
        state.func_call_name = (state.func_call_name or "") .. delta.function_call.name
      end
      if delta.function_call.arguments then
        state.func_call_args = state.func_call_args .. delta.function_call.arguments
      end
      return
    end

    if delta.content then
      local lines = split_content_to_lines(delta.content)
      local last_line, last_column = get_buffer_last_position(out_buf)
      vim.api.nvim_buf_set_text(out_buf, last_line, last_column, last_line, last_column, lines)
    end

    local finish_reason = choice.finish_reason
    if finish_reason == "stop" or finish_reason == "function_call" then
      if state.func_call_name ~= nil and state.func_call_args ~= "" then
        local func_lines = format_function_call_lines(state.func_call_name, state.func_call_args)
        vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, func_lines)
      end

      vim.api.nvim_buf_set_lines(out_buf, -1, -1, true, { "", "---" })
      vim.notify("Done.", vim.log.levels.INFO)

      state.func_call_name = nil
      state.func_call_args = ""
    elseif finish_reason ~= nil then
      vim.notify("An error occured during text generation. Reason: " .. finish_reason, vim.log.levels.ERROR)
    end
  end
end

-- Public API

---Send chat completion request to LLM and add response to output buffer
---@param in_buf integer Input markdown buffer number
---@param out_buf integer? Output markdown buffer number
M.chat_completion = function(in_buf, out_buf)
  local in_ft = vim.api.nvim_get_option_value("filetype", { buf = in_buf })
  if in_ft ~= "markdown" then
    log.debug("Input buffer is not a markdown buffer")
    error("Input buffer is not a markdown buffer")
  end

  if out_buf then
    local out_ft = vim.api.nvim_get_option_value("filetype", { buf = out_buf })
    if out_ft ~= "markdown" then
      log.debug("Output buffer is not a markdown buffer")
      error("Output buffer is not a markdown buffer")
    end
  end

  local request, md_str = prepare_chat_request(in_buf)
  out_buf = out_buf or in_buf

  vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, vim.split(md_str, "\n"))

  log.debug("request: ", request)
  vim.notify(string.format("Sending request to %s...(%d messages)", M.client.base_url, #request.messages))

  local completion_callback = create_chat_completion_callback(out_buf)
  local streaming_callback = create_streaming_callback(out_buf)

  M.client:chat_completion_create(request, completion_callback, streaming_callback)
end

-- Expose callback creators for testing
M.on_chat_completion = create_chat_completion_callback
M.on_chat_completion_chunk = create_streaming_callback

return M
