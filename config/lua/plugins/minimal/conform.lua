local vim = vim

return {
	'stevearc/conform.nvim',

	enabled = true,

	config = function()
		require('conform').setup({
			formatters_by_ft = {
				sh = { 'shfmt', 'shellharden' },
				zsh = { 'shfmt', 'shellharden' }, -- 'beautysh'
				python = { 'isort', 'black' },
				javascript = { 'prettier' },
				typescript = { 'prettier' },
				html = { 'prettier' },
				typescriptreact = { 'prettier' },
				go = { 'gofmt' },
				lua = { 'stylua' },
			},

			formatters = {
				shfmt = {
					prepend_args = { '--indent', '2', '--case-indent', '--language-dialect', 'posix', '--simplify' },
				},
			},
		})

		vim.keymap.set({ 'n', 'x' }, '<Leader>f', function()
			require('conform').format({ async = true, lsp_fallback = true })
		end)
	end,
}
