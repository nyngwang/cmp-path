local cmp = require 'cmp'

local NAME_REGEX = [[\%([^/\\:*?<>'"`|]\)]]
local PATH_REGEX = vim.regex(([[\%(\%(/PAT*[^/\\\\:\\*?<>\'"`\\| .~]\)\|\%(/\.\.\)\)*/\zePAT*$]]):gsub('PAT', NAME_REGEX))

local source = {}

local constants = {
  max_lines = 20,
}

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(): string

---@type cmp_path.Option
local defaults = {
  trailing_slash = false,
  label_trailing_slash = true,
  get_cwd = function(params)
    return vim.fn.expand(('#%d:p:h'):format(params.context.bufnr))
  end,
}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  return { '/', '.' }
end

source.get_keyword_pattern = function(self, params)
  return NAME_REGEX .. '*'
end

source.complete = function(self, params, callback)
  local option = self:_validate_option(params)

  local dirname = self:_dirname(params, option)
  if not dirname then
    return callback()
  end

  local include_hidden = string.sub(params.context.cursor_before_line, params.offset, params.offset) == '.'
  self:_candidates(dirname, include_hidden, option, function(err, candidates)
    if err then
      return callback()
    end
    callback(candidates)
  end)
end

source.resolve = function(self, completion_item, callback)
  local data = completion_item.data
  if data.stat and data.stat.type == 'file' then
    local ok, documentation = pcall(function()
      return self:_get_documentation(data.path, constants.max_lines)
    end)
    if ok then
      completion_item.documentation = documentation
    end
  end
  callback(completion_item)
end

source._dirname = function(self, params, option)
  -- print('cursor_before_line:', params.context.cursor_before_line)
  local s = PATH_REGEX:match_str(params.context.cursor_before_line)
  if not s then
    return nil
  end

  local dirname = string.gsub(string.sub(params.context.cursor_before_line, s + 2), '%a*$', '') -- exclude '/'
  local prefix = params.context.cursor_before_line -- string.sub(params.context.cursor_before_line, 1, s + 1) -- include '/'

  local buf_dirname = option.get_cwd(params)
  if vim.api.nvim_get_mode().mode == 'c' then
    buf_dirname = vim.fn.getcwd()
  end
  if prefix:match('%.%./$') then
    return vim.fn.resolve(buf_dirname .. '/../' .. dirname)
  end
  if (prefix:match('%./$') or prefix:match('"$') or prefix:match('\'$')) then
    return vim.fn.resolve(buf_dirname .. '/' .. dirname)
  end
  if prefix:match('~/$') then
    return vim.fn.resolve(vim.fn.expand('~') .. '/' .. dirname)
  end
  local env_var_name = prefix:match('%$([%a_]+)/$')
  if env_var_name then
    local env_var_value = vim.fn.getenv(env_var_name)
    if env_var_value ~= vim.NIL then
      return vim.fn.resolve(env_var_value .. '/' .. dirname)
    end
  end

  -- what it does: replace all alias by tsconfig.json located at the project root, which is the cwd when you open neovim.
  -- assumptions:
  -- 1. you should not use the same alias twice in your import path.
  -- 2. you should not append `../$`, `./$`, `~/$` to any import path starting with an alias.
  -- 3. you should only expect that for every key, only the first path will be used.
  -- 4. you should not expect intellisense before the first `/`.
  local project_root = vim.fn.getcwd(-1, -1)
  local tsconfig_path = project_root .. '/tsconfig.json'
  local fp = io.open(tsconfig_path, 'r')
  if fp then
    local ok, json_tsconfig = pcall(vim.json.decode, fp:read('*a'))
    if ok
      and json_tsconfig['compilerOptions']
      and json_tsconfig['compilerOptions']['paths']
    then
      local base = json_tsconfig['compilerOptions']['baseUrl'] or ''

      for key, paths in pairs(json_tsconfig['compilerOptions']['paths']) do
        local pattern = key:gsub('%*$', '')
        local path = paths[1]:gsub('%*$', '') -- only the first path is picked.

        if prefix:match(pattern) then -- no partial match for now.
          return vim.fn.resolve(project_root .. '/' .. base .. '/' .. prefix:match(pattern .. '%S*'):gsub(pattern, path))
        end
      end
    end
    fp:close()
  end

  if prefix:match('/$') then
    local accept = true
    -- Ignore URL components
    accept = accept and not prefix:match('%a/$')
    -- Ignore URL scheme
    accept = accept and not prefix:match('%a+:/$') and not prefix:match('%a+://$')
    -- Ignore HTML closing tags
    accept = accept and not prefix:match('</$')
    -- Ignore math calculation
    accept = accept and not prefix:match('[%d%)]%s*/$')
    -- Ignore / comment
    accept = accept and (not prefix:match('^[%s/]*$') or not self:_is_slash_comment())
    if accept then
      return vim.fn.resolve('/' .. dirname)
    end
  end
  return nil
end

source._candidates = function(_, dirname, include_hidden, option, callback)
  local fs, err = vim.loop.fs_scandir(dirname)
  if err then
    return callback(err, nil)
  end

  local items = {}

  local function create_item(name, fs_type)
    if not (include_hidden or string.sub(name, 1, 1) ~= '.') then
      return
    end

    local path = dirname .. '/' .. name
    local stat = vim.loop.fs_stat(path)
    local lstat = nil
    if stat then
      fs_type = stat.type
    elseif fs_type == 'link' then
      -- Broken symlink
      lstat = vim.loop.fs_lstat(dirname)
      if not lstat then
        return
      end
    else
      return
    end

    local item = {
      label = name,
      filterText = name,
      insertText = name,
      kind = cmp.lsp.CompletionItemKind.File,
      data = {
        path = path,
        type = fs_type,
        stat = stat,
        lstat = lstat,
      },
    }
    if fs_type == 'directory' then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      if option.label_trailing_slash then
        item.label = name .. '/'
      else
        item.label = name
      end
      item.insertText = name .. '/'
      if not option.trailing_slash then
        item.word = name
      end
    end
    table.insert(items, item)
  end

  while true do
    local name, fs_type, e = vim.loop.fs_scandir_next(fs)
    if e then
      return callback(fs_type, nil)
    end
    if not name then
      break
    end
    create_item(name, fs_type)
  end

  callback(nil, items)
end

source._is_slash_comment = function(_)
  local commentstring = vim.bo.commentstring or ''
  local no_filetype = vim.bo.filetype == ''
  local is_slash_comment = false
  is_slash_comment = is_slash_comment or commentstring:match('/%*')
  is_slash_comment = is_slash_comment or commentstring:match('//')
  return is_slash_comment and not no_filetype
end

---@return cmp_path.Option
source._validate_option = function(_, params)
  local option = vim.tbl_deep_extend('keep', params.option, defaults)
  vim.validate({
    trailing_slash = { option.trailing_slash, 'boolean' },
    label_trailing_slash = { option.label_trailing_slash, 'boolean' },
    get_cwd = { option.get_cwd, 'function' },
  })
  return option
end

source._get_documentation = function(_, filename, count)
  local binary = assert(io.open(filename, 'rb'))
  local first_kb = binary:read(1024)
  if first_kb:find('\0') then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = 'binary file' }
  end

  local contents = {}
  for content in first_kb:gmatch("[^\r\n]+") do
    table.insert(contents, content)
    if count ~= nil and #contents >= count then
      break
    end
  end

  local filetype = vim.filetype.match({ filename = filename })
  if not filetype then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = table.concat(contents, '\n') }
  end

  table.insert(contents, 1, '```' .. filetype)
  table.insert(contents, '```')
  return { kind = cmp.lsp.MarkupKind.Markdown, value = table.concat(contents, '\n') }
end

return source
