---@meta
--- This is a simple "definition file" (https://luals.github.io/wiki/definition-files/),
--- the @meta tag at the top is its hallmark.

-- NOTE: ChatML prefix is used to types from chatml.nvim types

-- NOTE: These files are not annotated with types. The code is from external sources.
--  lua/chatml/yaml.lua
--  lua/chatml/log.lua

-- lua/chatml/init.lua -----------------------------------------------------------

---@class ChatML
---@field setup fun(opts: ChatMLOptions): nil

-- lua/chatml/config.lua ---------------------------------------------------------

---@class ChatMLConfig
---@field defaults ChatMLOptions default options
---@field options ChatMLOptions user options
---@field setup fun(opts: ChatMLOptions): nil

---@class ChatMLOptions

-- lua/chatml/health.lua ---------------------------------------------------------

---@class ChatMLHealth
---@field check fun(): nil

-- lua/chatml/parse.lua ---------------------------------------------------------

---@class ChatMLMessage
---@field role string
---@field content? string
---@field function_call? ChatMLFunctionCall
---@field tool_calls? ChatMLToolCall[]
---@field name? string
---@field tool_call_id? string

---@class ChatMLToolCall
---@field id string
---@field type string
---@field function ChatMLFunctionCall

---@class ChatMLFunctionCall
---@field name string
---@field arguments string

---@class ChatMLRequest
---@field model string
---@field messages ChatMLMessage[]
---@field functions? table[]
---@field [string] any

---@class ChatMLParse
---@field json_to_md fun(json_str: string): string
---@field json_to_md_pure fun(json_str: string): string?, string?
---@field json_buf_to_md_buf fun(in_buf: integer, out_buf: integer?): integer?
---@field md_to_json fun(md_str: string): string
---@field md_to_json_pure fun(md_str: string): string?, string?
---@field md_buf_to_json_buf fun(in_buf: integer, out_buf: integer?): integer?

-- lua/chatml/llm.lua -----------------------------------------------------------

---@class ChatCompletionMessage
---@field role string
---@field content? string
---@field function_call? ChatMLFunctionCall
---@field name? string

---@class ChatCompletionChoice
---@field message? ChatCompletionMessage
---@field delta? ChatCompletionMessage
---@field finish_reason? string

---@class ChatCompletionResponse
---@field choices ChatCompletionChoice[]

---@class StreamingState
---@field last_role string
---@field func_call_name? string
---@field func_call_args string

---@class ChatMLLLM
---@field client AiClient llm client used to set request to provider
---@field chat_completion fun(in_buf: integer, out_buf: integer?): nil
---@field on_chat_completion fun(out_buf: integer): function
---@field on_chat_completion_chunk fun(out_buf: integer): function

-- Tool-related types

---@class ChatMLTool
---@field server_name string
---@field name string
---@field description string
---@field inputSchema table

---@class ChatMLToolResponse
---@field result? table
---@field error? string

---@class ChatMLToolContent
---@field text? string
---@field [string] any

---------------------------------------------------------------------------------
