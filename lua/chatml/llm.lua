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
  if not decode_ok or type(decoded_args) ~= "table" then
    return {}
  end
  return decoded_args
end

---Clean examples from function parameters
---@param func_def table Function definition with parameters
---@return table func_def Cleaned function definition
local function clean_function_examples(func_def)
  if not (func_def.parameters and func_def.parameters.properties) then
    return func_def
  end

  for _, param in pairs(func_def.parameters.properties) do
    param.examples = nil
  end
  return func_def
end

---Transform tool to function definition
---@param tool table Tool definition from hub
---@return table func_def Function definition for LLM
local function tool_to_function_def(tool)
  local func_def = {
    ["function"] = clean_function_examples({
      name = string.format("%s-%s", tool.server_name, tool.name),
      description = tool.description,
      parameters = tool.inputSchema,
    }),
    type = "function",
  }
  return func_def
end

---Add tools to chat completion request
---@param request table The chat completion request
---@param tools table[] Array of tools from hub
---@return table request The modified request
local function add_tools_to_request(request, tools)
  request["tools"] = request["tools"] or {}

  for _, tool in ipairs(tools) do
    table.insert(request["tools"], tool_to_function_def(tool))
  end

  print(vim.inspect(request["tools"]))

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

  if not (response and response.result and response.result.content) then
    return "{}"
  end

  local first_content = response.result.content[1]
  if first_content and first_content.text then
    return string.format("````json\n%s\n````", first_content.text)
  end

  return string.format("````json\n%s\n````", response.result.content)
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
  -- Remove trailing whitespace characters from the markdown content
  local cleaned_content = md_content:gsub("%s+$", "")
  local json_str = parse.md_to_json(cleaned_content)
  local ok, request = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })

  if not ok or type(request) ~= "table" then
    error("Cannot parse JSON string into request")
  end

  return add_tools_to_request(request, tools)
end

---Ensure buffer ends with separator
---@param buf integer Buffer number
---@return string content Final buffer content
local function ensure_buffer_separator(buf)
  local md_str = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local last_line = md_str:match("([^\n]*)\n?$") or ""

  if last_line == "---" then
    return md_str
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "---" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd.write()
  end)

  return ensure_buffer_separator(buf)
end

---Get tools from hub
---@return table[] tools Available tools
local function get_available_tools()
  local hub = require("mcphub").get_hub_instance()
  return hub and hub:get_tools() or {}
end

---Prepare chat completion request from markdown buffer
---@param in_buf integer Input markdown buffer
---@return table request Prepared request
local function prepare_chat_request(in_buf)
  local md_str = ensure_buffer_separator(in_buf)
  local tools = get_available_tools()
  local request = prepare_request_from_content(md_str, tools)
  return request
end

-- ============================================================================
-- TOOL EXECUTION
-- ============================================================================

---Handle tool execution error
---@param progress_id string Progress identifier
---@param err string Error message
local function handle_tool_error(progress_id, err)
  progress_manager:finish_handle(progress_id, "Tool call failed")
  vim.notify("Tool call error: " .. err, vim.log.levels.ERROR)
end

---Handle successful tool execution
---@param progress_id string Progress identifier
---@param out_buf integer Output buffer
---@param server_name string Server name
---@param func_name string Function name
---@param response any Tool response
local function handle_tool_success(progress_id, out_buf, server_name, func_name, response)
  progress_manager:update_handle(progress_id, "Processing tool response...", 80)

  local result_content = format_tool_result(response, nil)
  local func_name_lines = format_function_name_lines(string.format("%s-%s", server_name, func_name))
  local content_lines = split_content_to_lines(result_content)

  -- TODO: remove vim.schedule
  vim.schedule(function()
    append_lines_to_buffer(out_buf, { "", "# assistant", "" })
    append_lines_to_buffer(out_buf, func_name_lines)
    append_lines_to_buffer(out_buf, content_lines)
    append_lines_to_buffer(out_buf, { "", "---" })
    progress_manager:finish_handle(progress_id, "Tool call completed successfully")
  end)
end

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
      handle_tool_error(progress_id, err)
      return
    end
    handle_tool_success(progress_id, out_buf, server_name, func_name, response)
  end
end

---Get hub instance with error handling
---@return table hub Hub instance
local function get_hub_instance()
  local hub = require("mcphub").get_hub_instance()
  if not hub then
    error("No hub instance found. Please ensure mcphub is properly initialized.")
  end
  return hub
end

---Execute tool call asynchronously
---@param server_name string Server name
---@param func_name string Function name
---@param func_args table Function arguments
---@param out_buf integer Output buffer
local function async_call_tool_and_append(server_name, func_name, func_args, out_buf)
  local callback = create_tool_result_callback(out_buf, server_name, func_name)
  local hub = get_hub_instance()

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
  if not (server_name and func_name) then
    return request, false
  end

  async_call_tool_and_append(server_name, func_name, func_args, buf)
  return request, true
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

---Try to parse JSON from buffer
---@param buffer string JSON buffer
---@return boolean success Whether parsing succeeded
---@return table? obj Parsed object
local function try_parse_json(buffer)
  local ok, obj = pcall(vim.json.decode, buffer, { luanil = { object = true, array = true } })
  return ok, obj
end

---Process streaming data chunk
---@param raw_str string Raw data string
---@param buffer string Current buffer
---@param callback function Callback to invoke with parsed object
---@return string new_buffer Updated buffer
local function process_streaming_chunk(raw_str, buffer, callback)
  if not raw_str or raw_str == "" then
    return buffer
  end

  buffer = buffer .. raw_str
  local str = buffer:match("^data: (.+)") or buffer

  local ok, obj = try_parse_json(str)
  if ok and obj then
    callback(obj)
    return ""
  end

  return buffer
end

---Process non-streaming data
---@param data string[] Raw data array
---@param buffer string Current buffer
---@param callback function Callback to invoke with parsed object
---@return string new_buffer Updated buffer
local function process_non_streaming_data(data, buffer, callback)
  local raw_str = table.concat(data)
  if not raw_str or raw_str == "" then
    return buffer
  end

  buffer = buffer .. raw_str
  local ok, obj = try_parse_json(buffer)
  if ok and obj then
    callback(obj)
    return ""
  end

  return buffer
end

---Create on_stdout callback for jobstart with enhanced error handling.
---@param stream boolean Whether the request is streaming or not.
---@param on_chat_completion fun(ChatCompletionObject)? Callback for full completion response when stream == false or upon error.
---@param on_chat_completion_chunk fun(ChatCompletionChunkObject)? Callback for chunk completion when stream == true.
---@return function on_stdout_callback Callback function for job stdout.
local function create_on_stdout(stream, on_chat_completion, on_chat_completion_chunk)
  local buffer = ""

  return function(_, data, _)
    if stream then
      assert(on_chat_completion_chunk, "on_chat_completion_chunk callback must be provided for streaming requests")
      for _, raw_str in ipairs(data) do
        buffer = process_streaming_chunk(raw_str, buffer, on_chat_completion_chunk)
      end
    else
      assert(on_chat_completion, "on_chat_completion callback must be provided for non-streaming requests")
      buffer = process_non_streaming_data(data, buffer, on_chat_completion)
    end
  end
end

---Handle chat completion error
---@param progress_id string Progress identifier
---@param error table Error object
local function handle_chat_completion_error(progress_id, error)
  progress_manager:finish_handle(progress_id, "Chat completion failed")
  vim.notify("Chat completion error: " .. vim.inspect(error), vim.log.levels.ERROR)
end

---Process function call message
---@param message table Message with function call
---@param out_buf integer Output buffer
local function process_function_call_message(message, out_buf)
  local func_name = message.function_call.name or ""
  local args = message.function_call.arguments or ""
  local func_lines = format_function_call_lines(func_name, args)
  append_lines_to_buffer(out_buf, func_lines)

  local server_name, func_name_no_srv, func_args = extract_function_call_info(message)
  if server_name and func_name_no_srv then
    async_call_tool_and_append(server_name, func_name_no_srv, func_args, out_buf)
  end
end

---Process function role message
---@param message table Message with function role
---@param out_buf integer Output buffer
local function process_function_role_message(message, out_buf)
  if message.name then
    local func_name_lines = format_function_name_lines(message.name)
    append_lines_to_buffer(out_buf, func_name_lines)
  end
end

---Process message content
---@param message table Message with content
---@param out_buf integer Output buffer
local function process_message_content(message, out_buf)
  if not (message.content and message.content ~= "") then
    return
  end

  local content_lines = split_content_to_lines(message.content)
  append_lines_to_buffer(out_buf, content_lines)
  append_lines_to_buffer(out_buf, { "" })
end

---Create callback for non-streaming chat completion
---@param out_buf integer Output buffer
---@return function callback Callback function for chat completion
local function create_chat_completion_callback(out_buf)
  local last_role = ""
  local progress_id = string.format("chat_completion_%d", out_buf)

  progress_manager:create_handle(progress_id, "Chat Completion", "Waiting for LLM response...")

  return function(chat_completion_obj)
    progress_manager:update_handle(progress_id, "Processing response...", 50)

    if chat_completion_obj.error then
      handle_chat_completion_error(progress_id, chat_completion_obj.error)
      return
    end

    if not chat_completion_obj.choices or #chat_completion_obj.choices == 0 then
      progress_manager:finish_handle(progress_id, "Chat completion response has no choices")
      vim.notify("Chat completion response has no choices: " .. vim.inspect(chat_completion_obj), vim.log.levels.ERROR)
      return
    end

    local message = chat_completion_obj.choices[1].message
    local role = message.role

    if role and role ~= "" and last_role ~= role then
      local role_lines = format_role_header(role)
      append_lines_to_buffer(out_buf, role_lines)
      last_role = role
    end

    progress_manager:update_handle(progress_id, "Formatting response...", 70)

    if message.function_call then
      progress_manager:update_handle(progress_id, "Executing function call...", 80)
      process_function_call_message(message, out_buf)
    end

    if role == "function" then
      process_function_role_message(message, out_buf)
    end

    process_message_content(message, out_buf)
    append_lines_to_buffer(out_buf, { "---" })
    progress_manager:finish_handle(progress_id, "Chat completion finished")
  end
end

---Handle stream completion
---@param progress_id string Progress identifier
---@param state StreamingState Streaming state
---@param out_buf integer Output buffer
---@param chunk_count integer Number of chunks processed
---@param content_length integer Total content length
local function handle_stream_completion(progress_id, state, out_buf, chunk_count, content_length)
  if state.func_call_name and state.func_call_args ~= "" then
    local func_lines = format_function_call_lines(state.func_call_name, state.func_call_args)
    append_lines_to_buffer(out_buf, func_lines)
  end

  append_lines_to_buffer(out_buf, { "", "---" })
  progress_manager:finish_handle(
    progress_id,
    string.format("Stream completed (%d chunks, %d chars)", chunk_count, content_length)
  )

  reset_function_call_state(state)
end

---Handle stream error
---@param progress_id string Progress identifier
---@param finish_reason string Finish reason
local function handle_stream_error(progress_id, finish_reason)
  progress_manager:finish_handle(progress_id, "Stream failed: " .. finish_reason)
  vim.notify("An error occured during text generation. Reason: " .. finish_reason, vim.log.levels.ERROR)
end

---Process stream delta content
---@param delta table Delta object
---@param out_buf integer Output buffer
---@param content_length integer Current content length
---@return integer new_content_length Updated content length
local function process_stream_delta_content(delta, out_buf, content_length)
  if not delta.content then
    return content_length
  end

  local new_length = content_length + #delta.content
  local lines = split_content_to_lines(delta.content)
  local last_line, last_column = get_buffer_last_position(out_buf)
  insert_text_at_position(out_buf, last_line, last_column, lines)

  return new_length
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

    if chat_completion_chunk_obj.error then
      progress_manager:finish_handle(progress_id, "Stream failed")
      vim.notify("Chat completion stream error: " .. vim.inspect(chat_completion_chunk_obj.error), vim.log.levels.ERROR)
      return
    end

    local choice = chat_completion_chunk_obj.choices[1]
    local delta = choice.delta

    local role = delta.role
    if role and role ~= "" and state.last_role ~= role then
      progress_manager:update_handle(progress_id, string.format("Processing %s response...", role), nil)
      local role_lines = format_role_header(role)
      append_lines_to_buffer(out_buf, role_lines)
      state.last_role = role
    end

    if delta.function_call then
      local func_call_size = #(delta.function_call.name or "") + #(delta.function_call.arguments or "")
      content_length = content_length + func_call_size

      progress_manager:update_handle(
        progress_id,
        string.format("Receiving function call... (%d chars, %d chunks)", content_length, chunk_count),
        nil
      )

      update_function_call_state(state, delta.function_call)
      return
    end

    content_length = process_stream_delta_content(delta, out_buf, content_length)
    if delta.content then
      progress_manager:update_handle(
        progress_id,
        string.format("Streaming content... (%d chars, %d chunks)", content_length, chunk_count),
        nil
      )
    end

    local finish_reason = choice.finish_reason
    if finish_reason == "stop" or finish_reason == "function_call" then
      progress_manager:update_handle(progress_id, "Finalizing function call...", 90)
      handle_stream_completion(progress_id, state, out_buf, chunk_count, content_length)
    elseif finish_reason then
      handle_stream_error(progress_id, finish_reason)
    end
  end
end

---Validate input and output buffers
---@param in_buf integer Input buffer
---@param out_buf integer? Output buffer
---@return integer out_buf Validated output buffer
local function validate_buffers(in_buf, out_buf)
  if not validate_buffer_filetype(in_buf, "markdown") then
    vim.notify("Input buffer is not a markdown buffer")
    error("Input buffer is not a markdown buffer")
  end

  local actual_out_buf = out_buf or in_buf
  if not validate_buffer_filetype(actual_out_buf, "markdown") then
    vim.notify("Output buffer is not a markdown buffer")
    error("Output buffer is not a markdown buffer")
  end

  return actual_out_buf
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

  -- Early validation and setup
  out_buf = validate_buffers(in_buf, out_buf)

  progress_manager:update_handle(main_progress_id, "Parsing request...", 25)
  local request = prepare_chat_request(in_buf)

  progress_manager:update_handle(main_progress_id, "Checking for tool calls...", 50)
  local _, is_tool_used = handle_last_function_call(request, out_buf)

  if is_tool_used then
    progress_manager:finish_handle(main_progress_id, "Tool call initiated")
    vim.notify("Tool was called, skipping LLM request")
    return
  end

  progress_manager:update_handle(main_progress_id, "Sending to LLM...", 75)

  local completion_callback = not request.stream and create_chat_completion_callback(out_buf) or nil
  local streaming_callback = request.stream and create_streaming_callback(out_buf) or nil
  local on_stdout_callback = create_on_stdout(request.stream, completion_callback, streaming_callback)

  progress_manager:finish_handle(main_progress_id, "Request sent to LLM")
  M.client:chat_completion_create(request, completion_callback, streaming_callback, on_stdout_callback)
end

return M
