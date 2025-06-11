local parse = require("chatml.parse")
local ai = require("ai")
local progress_manager = require("chatml.progress_manager")

---@class ChatMLLLM
local M = {}

M.client = ai.Client:new()

-- ============================================================================
-- PURE UTILITY FUNCTIONS
-- ============================================================================

---Split content into lines
---@param content string Content to split
---@return string[] lines The split content lines
local function split_content_to_lines(content)
  return vim.split(content, "\n", { plain = true, trimempty = false })
end

---Parse function name from tool call format
---@param func_call_name string Function call name in format "server-function"
---@return string? server_name Server name
---@return string? func_name Function name
local function parse_tool_name(func_call_name)
  return func_call_name:match("([^%-]+)%-([^%-]+)")
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

---Clean examples from function parameters
---@param func_def table Function definition with parameters
---@return table func_def Cleaned function definition
local function clean_function_examples(func_def)
  if func_def.parameters and func_def.parameters.properties then
    for _, param in pairs(func_def.parameters.properties) do
      param.examples = nil
    end
  end
  return func_def
end

---Transform tool to function definition
---@param tool table Tool definition from hub
---@return table func_def Function definition for LLM
local function tool_to_function_def(tool)
  local func_def = {
    name = string.format("%s-%s", tool.server_name, tool.name),
    description = tool.description,
    parameters = tool.inputSchema,
  }
  return clean_function_examples(func_def)
end

---Add tools to chat completion request
---@param request table The chat completion request
---@param tools table[] Array of tools from hub
---@return table request The modified request
local function add_tools_to_request(request, tools)
  request["functions"] = request["functions"] or {}

  for _, tool in ipairs(tools) do
    table.insert(request["functions"], tool_to_function_def(tool))
  end

  return request
end

---Check if message has function call
---@param message table Chat message
---@return boolean has_function_call Whether message has function call
local function has_function_call(message)
  return message and message.role == "assistant" and message.function_call
end

---Extract function call info from message
---@param message table Chat message with function call
---@return string? server_name Server name
---@return string? func_name Function name
---@return table func_args Function arguments
local function extract_function_call_info(message)
  if not has_function_call(message) then
    return nil, nil, {}
  end

  local server_name, func_name = parse_tool_name(message.function_call.name)
  local func_args = parse_function_arguments(message.function_call.arguments)

  return server_name, func_name, func_args
end

-- ============================================================================
-- FORMATTING FUNCTIONS
-- ============================================================================

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
  args = args:gsub("\n", "")
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

-- ============================================================================
-- BUFFER OPERATIONS (EXTERNAL DEPENDENCIES)
-- ============================================================================

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

---Append lines to buffer
---@param buf integer Buffer number
---@param lines string[] Lines to append
local function append_lines_to_buffer(buf, lines)
  vim.api.nvim_buf_set_lines(buf, -1, -1, true, lines)
end

---Insert text at buffer position
---@param buf integer Buffer number
---@param line integer Line number
---@param col integer Column number
---@param text string[] Text lines to insert
local function insert_text_at_position(buf, line, col, text)
  vim.api.nvim_buf_set_text(buf, line, col, line, col, text)
end

---Replace buffer content
---@param buf integer Buffer number
---@param content string Content to set
local function replace_buffer_content(buf, content)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
end

---Validate buffer filetype
---@param buf integer Buffer number
---@param expected_ft string Expected filetype
---@return boolean is_valid Whether buffer has expected filetype
local function validate_buffer_filetype(buf, expected_ft)
  local actual_ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
  return actual_ft == expected_ft
end

-- ============================================================================
-- REQUEST PREPARATION
-- ============================================================================

---Prepare chat completion request from markdown buffer content
---@param md_content string Markdown content
---@param tools table[] Available tools
---@return table request Prepared request
local function prepare_request_from_content(md_content, tools)
  local cleaned_content = md_content:gsub("%s+$", "")
  local json_str = parse.md_to_json(cleaned_content)
  local ok, request = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })

  if not ok or type(request) ~= "table" then
    error("Cannot parse JSON string into request")
  end

  return add_tools_to_request(request, tools)
end

---Get markdown content from buffer
---@param buf integer Buffer number
---@return string content Markdown content
local function get_buffer_content(buf)
  local md_str = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

  -- if last line of md_str is not ---, then append it
  local last_line = md_str:match("([^\n]*)\n?$") or ""
  if last_line ~= "---" then
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "---" })

    -- save after setting lines
    vim.api.nvim_buf_call(buf, function()
      vim.cmd.write()
    end)

    return get_buffer_content(buf)
  end

  return md_str
end

---Prepare chat completion request from markdown buffer
---@param in_buf integer Input markdown buffer
---@return table request Prepared request
---@return string md_str Final markdown string
local function prepare_chat_request(in_buf)
  local md_str = get_buffer_content(in_buf)
  local tools = {}

  local hub = require("mcphub").get_hub_instance()
  if hub ~= nil then
    tools = hub:get_tools()
  end

  local request = prepare_request_from_content(md_str, tools)
  return request, md_str
end

-- ============================================================================
-- TOOL EXECUTION
-- ============================================================================

---Create tool result callback
---@param out_buf integer Output buffer
---@param server_name string Server name
---@param func_name string Function name
---@return function callback Tool result callback
local function create_tool_result_callback(out_buf, server_name, func_name)
  local progress_id = string.format("tool_%s_%s_%d", server_name, func_name, out_buf)

  progress_manager:create_handle(
    progress_id,
    string.format("Tool Call: %s-%s", server_name, func_name),
    string.format("Calling %s on %s server...", func_name, server_name)
  )

  return function(response, err)
    if err then
      progress_manager:finish_handle(progress_id, "Tool call failed")
      vim.notify("Tool call error: " .. err, vim.log.levels.ERROR)
      return
    end

    progress_manager:update_handle(progress_id, "Processing tool response...", 80)

    local result_content = format_tool_result(response, err)
    local func_name_lines = format_function_name_lines(string.format("%s-%s", server_name, func_name))
    local content_lines = split_content_to_lines(result_content)

    vim.schedule(function()
      append_lines_to_buffer(out_buf, { "", "# assistant", "" })
      append_lines_to_buffer(out_buf, func_name_lines)
      append_lines_to_buffer(out_buf, content_lines)
      append_lines_to_buffer(out_buf, { "", "---" })

      progress_manager:finish_handle(progress_id, "Tool call completed successfully")
    end)
  end
end

---Execute tool call asynchronously
---@param server_name string Server name
---@param func_name string Function name
---@param func_args table Function arguments
---@param out_buf integer Output buffer
local function async_call_tool_and_append(server_name, func_name, func_args, out_buf)
  local callback = create_tool_result_callback(out_buf, server_name, func_name)

  local hub = require("mcphub").get_hub_instance()
  if hub == nil then
    error("No hub instance found. Please ensure mcphub is properly initialized.")
  end

  hub:call_tool(server_name, func_name, func_args, {
    return_text = true,
    callback = callback,
  })
end

---Handle function call in last assistant message
---@param request table The chat completion request
---@param buf integer Buffer number to append tool result
---@return table request The unmodified request
---@return boolean tool_called Whether a tool was called
local function handle_last_function_call(request, buf)
  local last_msg = request.messages[#request.messages]
  if not has_function_call(last_msg) then
    return request, false
  end

  local server_name, func_name, func_args = extract_function_call_info(last_msg)
  if server_name and func_name then
    async_call_tool_and_append(server_name, func_name, func_args, buf)
    return request, true
  end

  return request, false
end

-- ============================================================================
-- STREAMING STATE MANAGEMENT
-- ============================================================================

---Create initial streaming state
---@return StreamingState state Initial state
local function create_streaming_state()
  return {
    last_role = "",
    func_call_name = nil,
    func_call_args = "",
  }
end

---Update streaming state with function call delta
---@param state StreamingState Current state
---@param func_call table Function call delta
---@return StreamingState state Updated state
local function update_function_call_state(state, func_call)
  if func_call.name then
    state.func_call_name = (state.func_call_name or "") .. func_call.name
  end
  if func_call.arguments then
    state.func_call_args = state.func_call_args .. func_call.arguments
  end
  return state
end

---Reset function call state
---@param state StreamingState Current state
---@return StreamingState state Reset state
local function reset_function_call_state(state)
  state.func_call_name = nil
  state.func_call_args = ""
  return state
end

-- ============================================================================
-- CALLBACK CREATORS
-- ============================================================================

---Create callback for non-streaming chat completion
---@param out_buf integer Output buffer
---@return function callback Callback function for chat completion
local function create_chat_completion_callback(out_buf)
  local last_role = ""
  local progress_id = string.format("chat_completion_%d", out_buf)

  progress_manager:create_handle(progress_id, "Chat Completion", "Waiting for LLM response...")

  return function(chat_completion_obj)
    progress_manager:update_handle(progress_id, "Processing response...", 50)

    local message = chat_completion_obj.choices[1].message
    local role = message.role

    if role ~= nil and role ~= "" and last_role ~= role then
      local role_lines = format_role_header(role)
      append_lines_to_buffer(out_buf, role_lines)
      last_role = role
    end

    progress_manager:update_handle(progress_id, "Formatting response...", 70)

    if message.function_call then
      local func_name = message.function_call.name or ""
      local args = message.function_call.arguments or ""
      local func_lines = format_function_call_lines(func_name, args)
      append_lines_to_buffer(out_buf, func_lines)

      progress_manager:update_handle(progress_id, "Executing function call...", 80)

      local server_name, func_name_no_srv, func_args = extract_function_call_info(message)
      if server_name and func_name_no_srv then
        async_call_tool_and_append(server_name, func_name_no_srv, func_args, out_buf)
      end
    end

    if role == "function" and message.name then
      local func_name_lines = format_function_name_lines(message.name)
      append_lines_to_buffer(out_buf, func_name_lines)
    end

    if message.content and message.content ~= "" then
      local content_lines = split_content_to_lines(message.content)
      append_lines_to_buffer(out_buf, content_lines)
      append_lines_to_buffer(out_buf, { "" })
    end

    append_lines_to_buffer(out_buf, { "---" })
    progress_manager:finish_handle(progress_id, "Chat completion finished")
  end
end

---Create callback for streaming chat completion
---@param out_buf integer Output buffer
---@return function callback Callback function for chat completion chunks
local function create_streaming_callback(out_buf)
  local state = create_streaming_state()
  local progress_id = string.format("chat_stream_%d", out_buf)

  progress_manager:create_handle(progress_id, "Chat Completion Stream", "Starting stream...")

  local chunk_count = 0
  local content_length = 0

  return function(chat_completion_chunk_obj)
    chunk_count = chunk_count + 1

    local choice = chat_completion_chunk_obj.choices[1]
    local delta = choice.delta

    local role = delta.role
    if role ~= nil and role ~= "" and state.last_role ~= role then
      progress_manager:update_handle(progress_id, string.format("Processing %s response...", role), nil)
      local role_lines = format_role_header(role)
      append_lines_to_buffer(out_buf, role_lines)
      state.last_role = role
    end

    if delta.function_call then
      if delta.function_call then
        content_length = content_length + #(delta.function_call.name or "") + #(delta.function_call.arguments or "")
      end

      progress_manager:update_handle(
        progress_id,
        string.format("Receiving function call... (%d chars, %d chunks)", content_length, chunk_count),
        nil
      )

      update_function_call_state(state, delta.function_call)
      return
    end

    if delta.content then
      content_length = content_length + #delta.content
      progress_manager:update_handle(
        progress_id,
        string.format("Streaming content... (%d chars, %d chunks)", content_length, chunk_count),
        nil
      )

      local lines = split_content_to_lines(delta.content)
      local last_line, last_column = get_buffer_last_position(out_buf)
      insert_text_at_position(out_buf, last_line, last_column, lines)
    end

    local finish_reason = choice.finish_reason
    if finish_reason == "stop" or finish_reason == "function_call" then
      if state.func_call_name ~= nil and state.func_call_args ~= "" then
        progress_manager:update_handle(progress_id, "Finalizing function call...", 90)
        local func_lines = format_function_call_lines(state.func_call_name, state.func_call_args)
        append_lines_to_buffer(out_buf, func_lines)
      end

      append_lines_to_buffer(out_buf, { "", "---" })
      progress_manager:finish_handle(
        progress_id,
        string.format("Stream completed (%d chunks, %d chars)", chunk_count, content_length)
      )

      reset_function_call_state(state)
    elseif finish_reason ~= nil then
      progress_manager:finish_handle(progress_id, "Stream failed: " .. finish_reason)
      vim.notify("An error occured during text generation. Reason: " .. finish_reason, vim.log.levels.ERROR)
    end
  end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Send chat completion request to LLM and add response to output buffer
---@param in_buf integer Input markdown buffer number
---@param out_buf integer? Output markdown buffer number
M.chat_completion = function(in_buf, out_buf)
  local main_progress_id = string.format("main_completion_%d", in_buf)

  progress_manager:create_handle(main_progress_id, "Chat Request", "Preparing request...")

  -- Validation
  if not validate_buffer_filetype(in_buf, "markdown") then
    progress_manager:finish_handle(main_progress_id, "Invalid input buffer")
    vim.notify("Input buffer is not a markdown buffer")
    error("Input buffer is not a markdown buffer")
  end

  if out_buf and not validate_buffer_filetype(out_buf, "markdown") then
    progress_manager:finish_handle(main_progress_id, "Invalid output buffer")
    vim.notify("Output buffer is not a markdown buffer")
    error("Output buffer is not a markdown buffer")
  end

  progress_manager:update_handle(main_progress_id, "Parsing request...", 25)

  local request, md_str = prepare_chat_request(in_buf)
  out_buf = out_buf or in_buf

  progress_manager:update_handle(main_progress_id, "Checking for tool calls...", 50)

  local is_tool_used
  request, is_tool_used = handle_last_function_call(request, out_buf)

  if is_tool_used then
    progress_manager:finish_handle(main_progress_id, "Tool call initiated")
    vim.notify("Tool was called, skipping LLM request")
    return
  end

  progress_manager:update_handle(main_progress_id, "Sending to LLM...", 75)

  replace_buffer_content(out_buf, md_str)

  local completion_callback = not request.stream and create_chat_completion_callback(out_buf) or nil
  local streaming_callback = request.stream and create_streaming_callback(out_buf) or nil

  -- Finish main progress since actual completion progress is handled by callbacks
  progress_manager:finish_handle(main_progress_id, "Request sent to LLM")

  M.client:chat_completion_create(request, completion_callback, streaming_callback)
end

-- Expose callback creators for testing
M.on_chat_completion = create_chat_completion_callback
M.on_chat_completion_chunk = create_streaming_callback

return M
