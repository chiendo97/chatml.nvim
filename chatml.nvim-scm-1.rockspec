---@diagnostic disable: lowercase-global
local _MODREV, _SPECREV = "scm", "-1"
rockspec_format = "3.0"
version = _MODREV .. _SPECREV

local user = "S1M0N38"
package = "chatml.nvim"

description = {
	summary = "OpenAI chat completion request (JSON) ⇋ markdown & sent requests",
	labels = { "neovim" },
	homepage = "https://github.com/" .. user .. "/" .. package,
	license = "MIT",
}

dependencies = {}

test_dependencies = {
	"nlua",
	"tree-sitter-yaml == 0.0.30-1",
}

source = {
	url = "git://github.com/" .. user .. "/" .. package,
}

build = {
	type = "builtin",
}
