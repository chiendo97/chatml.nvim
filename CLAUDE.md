# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

chatml.nvim is a Neovim plugin that provides bidirectional conversion between markdown and JSON formats for LLM chat completion requests. It follows the [chat-completion-md](https://github.com/S1M0N38/chat-completion-md) specification and supports OpenAI-compatible APIs.

## Core Architecture

The plugin is structured around several key modules:

- **lua/chatml/parse.lua**: Core parsing logic for markdown ⇋ JSON conversion
- **lua/chatml/llm.lua**: LLM integration for sending requests to providers
- **lua/chatml/config.lua**: Configuration management
- **lua/chatml/chat.lua**: Chat functionality implementation
- **lua/chatml/yaml.lua**: YAML parsing utilities for front matter
- **lua/chatml/types.lua**: Type definitions and interfaces

## Development Commands

### Running Tests

```bash
# Run all tests using busted (via GitHub Actions setup)
busted spec/
```

### Type Checking

The project uses lua-language-server for type checking:

```bash
# Type checking is configured via .github/workflows/.luarc.json
# Run manually with lua-language-server or use the GitHub Action
```

### Test Structure

- Tests are located in `spec/` directory
- Test data is in `spec/data/` with examples for both conversion directions
- Uses busted testing framework with descriptive test names

## Key Implementation Details

### Markdown to JSON Conversion

The core conversion process:

1. Parse YAML front matter for request metadata (model, temperature, etc.)
2. Extract messages from markdown sections marked with `# role`
3. Parse special blocks like `### function_call:` and `### tool_call:`
4. Validate message structure and roles
5. Combine into valid OpenAI chat completion request

### JSON to Markdown Conversion

The reverse process:

1. Extract metadata (excluding messages/functions)
2. Convert to YAML front matter
3. Format each message as markdown with role headers
4. Handle special function calls and tool calls appropriately

### File Include System

The plugin supports `#file:path` syntax in markdown messages to dynamically include file contents, enabling easy context injection.

### Testing Strategy

- Comprehensive test coverage for both conversion directions
- Error handling validation for malformed inputs
- Buffer operation testing for Neovim integration
- Test files use realistic examples from spec/data/

## Dependencies

- **Core**: Neovim ≥ 0.10, nvim-treesitter (for markdown/yaml/json parsing)
- **Optional**: ai.nvim (for LLM provider integration), cURL (for HTTP requests)
- **Development**: busted (testing), lua-language-server (type checking)

## Plugin Integration

The plugin integrates with Neovim through:

- Buffer operations for in-place conversion
- Filetype detection (markdown ↔ json)
- Key mappings for conversion and LLM requests
- Health checks via lua/chatml/health.lua

