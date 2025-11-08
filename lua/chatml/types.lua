---@meta
--- This is a simple "definition file" (https://luals.github.io/wiki/definition-files/),
--- the @meta tag at the top is its hallmark.

-- NOTE: ChatML prefix is used to types from chatml.nvim types

-- NOTE: These files are not annotated with types. The code is from external sources.
--  lua/chatml/yaml.lua
--  lua/chatml/log.lua

-- lua/chatml/init.lua -----------------------------------------------------------

---@class ChatML
---@field setup fun(opts?: ChatMLOptions): nil

-- lua/chatml/config.lua ---------------------------------------------------------

---@class ChatMLConfig
---@field defaults ChatMLOptions default options
---@field options ChatMLOptions user options
---@field setup fun(opts?: ChatMLOptions): nil

---@class ChatMLOptions
-- TODO: Define specific options if any

-- lua/chatml/health.lua ---------------------------------------------------------

---@class ChatMLHealth
---@field check fun(): nil

-- lua/chatml/parse.lua ---------------------------------------------------------

---@class ChatMLMessage : ChatMessage
---@field role string
---@field content? string
---@field function_call? ChatMLFunctionCall
---@field tool_calls? ChatMLToolCall[]
---@field name? string           -- For role = "function" or "tool"
---@field tool_call_id? string -- For role = "tool"

---@class ChatMLToolCall
---@field id string
---@field type string -- e.g., "function"
---@field function ChatMLFunctionCall

---@class ChatMLFunctionCall
---@field name string
---@field arguments string -- JSON string of arguments

---@class ChatMLRequest : RequestObject
---@field model string
---@field messages ChatMLMessage[]
---@field tools? table[] -- Array of tool definitions (OpenAI format)
---@field stream? boolean
---@field parallel_tool_calls? boolean
---@field [string] any -- Allow other provider-specific fields

---@class ChatMLParse
---@field json_to_md fun(json_str: string): string
---@field json_to_md_pure fun(json_str: string): string?, string?
---@field json_buf_to_md_buf fun(in_buf: integer, out_buf?: integer): integer?
---@field md_to_json fun(md_str: string): string
---@field md_to_json_pure fun(md_str: string): string?, string?
---@field md_buf_to_json_buf fun(in_buf: integer, out_buf?: integer): integer?

-- lua/chatml/llm.lua -----------------------------------------------------------

---@class ChatCompletionMessage -- Represents message structure in LLM responses (full or delta)
---@field role? string -- Optional in delta
---@field content? string
---@field function_call? ChatMLFunctionCall -- Older style, may appear in delta
---@field tool_calls? ChatMLToolCall[]   -- Newer style, may appear in delta
---@field name? string                   -- For role = "function" or "tool"
---@field tool_call_id? string           -- For role = "tool"

---@class ChatCompletionChoice
---@field message? ChatCompletionMessage     -- For non-streaming response
---@field delta? ChatCompletionMessage       -- For streaming response chunk
---@field finish_reason? string
---@field index? integer

---@class ChatCompletionResponse -- Covers both full and chunked/streamed responses
---@field id? string
---@field object? string -- e.g., "chat.completion" or "chat.completion.chunk"
---@field created? number
---@field model? string
---@field choices ChatCompletionChoice[]
---@field usage? table -- For non-streaming response
---@field error? table -- If an error occurred

---@class StreamingState
---@field last_role string
---@field func_call_name? string
---@field func_call_args string
---@field tool_call_id? string

---@class ChatMLLLM
---@field client AiClient llm client used to set request to provider
---@field chat_completion fun(in_buf: integer, out_buf?: integer): nil
---@field on_chat_completion fun(out_buf: integer): fun(chat_completion_obj: ChatCompletionResponse):nil -- Kept for potential direct use, though create_chat_completion_callback is internal
---@field on_chat_completion_chunk fun(out_buf: integer): fun(chat_completion_chunk_obj: ChatCompletionResponse):nil -- Kept for potential direct use, though create_streaming_callback is internal

-- lua/chatml/chat.lua -----------------------------------------------------------

---@class ChatMLChat
---@field picker fun(): nil
---@field new_chat fun(): nil
---@field paste_selection fun(): nil

---------------------------------------------------------------------------------
