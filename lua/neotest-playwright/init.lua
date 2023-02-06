---@diagnostic disable: undefined-field
local async = require("neotest.async")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local util = require("neotest-jest.util")

---@class neotest.JestOptions
---@field jestCommand? string|fun(): string
---@field jestConfigFile? string|fun(): string
---@field env? table<string, string>|fun(): table<string, string>
---@field cwd? string|fun(): string
---@field strategy_config? table<string, unknown>|fun(): table<string, unknown>

---@type neotest.Adapter
local adapter = { name = "neotest-playwright" }

adapter.root = lib.files.match_root_pattern("package.json")

---@param file_path? string
---@return boolean
function adapter.is_test_file(file_path)
  if file_path == nil then
    return false
  end

  if string.match(file_path, "__tests__") then
    return true
  end

  for _, x in ipairs({ "spec", "test" }) do
    for _, ext in ipairs({ "js", "jsx", "coffee", "ts", "tsx" }) do
      if string.match(file_path, x .. "%." .. ext .. "$") then
        return true
      end
    end
  end

  return false
end

function adapter.filter_dir(name)
  return name ~= "node_modules"
end

---@async
---@return neotest.Tree | nil
function adapter.discover_positions(path)
  local query = [[
		; -- Namespaces --
		; Matches: test.describe('title')

		(call_expression
		 function: (member_expression) @func_name (#eq? @func_name "test.describe")

		 arguments: (arguments
			 (string (string_fragment) @namespace.name)
			 ) @namespace.definition
		 )

		 ; -- Tests --
		 ; Matches: test('test')

		 (call_expression
			function: (identifier) @func_name (#eq? @func_name "test")

			arguments: (arguments
				(string (string_fragment) @test.name
				)
				) @test.definition
		 )
  ]]

  return lib.treesitter.parse_positions(path, query, { nested_tests = true })
end

---@param path string
---@return string
local function getJestCommand(path)
  local gitAncestor = util.find_git_ancestor(path)

  local function findBinary(p)
    local rootPath = util.find_node_modules_ancestor(p)
    local jestBinary = util.path.join(rootPath, "node_modules", ".bin", "playwright")

    if util.path.exists(jestBinary) then
      return jestBinary
    end

    -- If no binary found and the current directory isn't the parent
    -- git ancestor, let's traverse up the tree again
    if rootPath ~= gitAncestor then
      return findBinary(util.path.dirname(rootPath))
    end
  end

  local foundBinary = findBinary(path)

  if foundBinary then
    return foundBinary
  end

  return "playwright"
end

local jestConfigPattern = util.root_pattern("playwright.config.{js,ts}")

---@param path string
---@return string|nil
local function getJestConfig(path)
  local rootPath = jestConfigPattern(path)

  if not rootPath then
    return nil
  end

  local jestJs = util.path.join(rootPath, "playwright.config.js")
  local jestTs = util.path.join(rootPath, "playwright.config.ts")

  if util.path.exists(jestTs) then
    return jestTs
  end

  return jestJs
end

local function escapeTestPattern(s)
  return (
    s:gsub("%(", "%\\(")
      :gsub("%)", "%\\)")
      :gsub("%]", "%\\]")
      :gsub("%[", "%\\[")
      :gsub("%*", "%\\*")
      :gsub("%+", "%\\+")
      :gsub("%-", "%\\-")
      :gsub("%?", "%\\?")
      :gsub("%$", "%\\$")
      :gsub("%^", "%\\^")
      :gsub("%/", "%\\/")
      :gsub("%'", "%\\'")
  )
end

local function get_default_strategy_config(strategy, command, cwd)
  local config = {
    dap = function()
      return {
        name = "Debug Playwright Tests",
        type = "pwa-node",
        request = "launch",
        args = { unpack(command, 2) },
        runtimeExecutable = command[1],
        console = "integratedTerminal",
        internalConsoleOptions = "neverOpen",
        rootPath = "${workspaceFolder}",
        cwd = cwd or "${workspaceFolder}",
      }
    end,
  }
  if config[strategy] then
    return config[strategy]()
  end
end

local function getEnv(specEnv)
  return specEnv
end

---@param path string
---@return string|nil
local function getCwd(path)
  return nil
end

local function getStrategyConfig(default_strategy_config, args)
  return default_strategy_config
end

local function cleanAnsi(s)
  return s:gsub("\x1b%[%d+;%d+;%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+m", "")
    :gsub("\x1b%[%d+m", "")
end

local function findErrorPosition(file, errStr)
  -- Look for: /path/to/file.js:123:987
  local regexp = file:gsub("([^%w])", "%%%1") .. "%:(%d+)%:(%d+)"
  local _, _, errLine, errColumn = string.find(errStr, regexp)

  return errLine, errColumn
end

---@param data table Test output
---@param output_file string Path to output file
---@param consoleOut string Path to console output file
---@return neotest.Result[] | nil
local function parsed_json_to_results(data, output_file, consoleOut)
  local tests = {}

  -- TODO: remove after implementing parse logic for playwright
  if type(data.suites) ~= "table" then
    return {}
  end

  -- Vitests, playwright
  -- testResults -> suites
  -- testResult.name (absolute path) -> suite.file (relative path?)
  -- assertionResults -> specs
  -- assertionResult.status "passed" -> spec.ok (boolean)
  -- assertionResult.title -> spec.title

  for _, testResult in pairs(data.suites) do
    local testFn = testResult.name -- fullpath in vitest, filename in playwright

    for _, assertionResult in pairs(testResult.specs) do
      local ok, name = assertionResult.status, assertionResult.title

      if name == nil then
        logger.error("Failed to find parsed test result ", assertionResult)
        return {}
      end

      local keyid = assertionResult.id

      local status = nil
      if ok then
        status = "passed"
      else
        status = "failed"
      end

      tests[keyid] = {
        status = status,
        short = name .. ": " .. status,
        output = consoleOut,
        -- location = {
        --   line = assertionResult.line,
        --   column = assertionResult.column,
        -- },
      }

      if not vim.tbl_isempty(assertionResult.failureMessages) then
        local errors = {}

        for i, failMessage in ipairs(assertionResult.failureMessages) do
          local msg = cleanAnsi(failMessage)
          local errorLine, errorColumn = findErrorPosition(testFn, msg)

          errors[i] = {
            line = (errorLine or assertionResult.location.line) - 1,
            column = (errorColumn or 1) - 1,
            message = msg,
          }

          tests[keyid].short = tests[keyid].short .. "\n" .. msg
        end

        tests[keyid].errors = errors
      end
    end
  end

  return tests
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function adapter.build_spec(args)
  local results_path = async.fn.tempname() .. ".json"
  local tree = args.tree

  if not tree then
    return
  end

  local pos = args.tree:data()

  local binary = getJestCommand(pos.path)
  local config = getJestConfig(pos.path) or "playwright.config.ts"
  local command = vim.split(binary, "%s+")
  table.insert(command, "test")
  if util.path.exists(config) then
    -- only use config if available
    table.insert(command, "--config=" .. config)
  end

  local env = getEnv(args[2] and args[2].env or {})
  env.PLAYWRIGHT_JSON_OUTPUT_NAME = results_path

  local test_filter = ""

  -- use line number to target tests
  if pos.type == "test" or pos.type == "namespace" then
    test_filter = pos.path .. ":" .. pos.range[1] + 1
  else
    test_filter = pos.path
  end

  table.insert(command, test_filter)
  vim.list_extend(command, {
    "--reporter=json",
    -- "--outputFile=" .. results_path,
  })

  -- DEBUG:
  -- print(vim.inspect(command))
  print(table.concat(command, " "))

  local cwd = getCwd(pos.path)

  -- creating empty file for streaming results
  lib.files.write(results_path, "")
  local stream_data, stop_stream = util.stream(results_path)

  return {
    command = command,
    cwd = cwd,
    context = {
      results_path = results_path,
      file = pos.path,
      stop_stream = stop_stream,
    },
    stream = function()
      return function()
        local new_results = stream_data()
        local ok, parsed = pcall(vim.json.decode, new_results, { luanil = { object = true } })

        if not ok or not parsed.suites then
          return {}
        end

        return parsed_json_to_results(parsed, results_path, nil)
      end
    end,
    strategy = getStrategyConfig(
      get_default_strategy_config(args.strategy, command, cwd) or {},
      args
    ),
    env = env,
  }
end

---@async
---@param spec neotest.RunSpec
---@return neotest.Result[]
function adapter.results(spec, b, tree)
  spec.context.stop_stream()

  local output_file = spec.context.results_path

  local success, data = pcall(lib.files.read, output_file)

  if not success then
    logger.error("No test output file found ", output_file)
    return {}
  end

  local ok, parsed = pcall(vim.json.decode, data, { luanil = { object = true } })

  if not ok then
    logger.error("Failed to parse test output json ", output_file)
    return {}
  end

  local results = parsed_json_to_results(parsed, output_file, b.output)

  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(adapter, {
  ---@param opts neotest.JestOptions
  __call = function(_, opts)
    if is_callable(opts.jestCommand) then
      getJestCommand = opts.jestCommand
    elseif opts.jestCommand then
      getJestCommand = function()
        return opts.jestCommand
      end
    end
    if is_callable(opts.jestConfigFile) then
      getJestConfig = opts.jestConfigFile
    elseif opts.jestConfigFile then
      getJestConfig = function()
        return opts.jestConfigFile
      end
    end
    if is_callable(opts.env) then
      getEnv = opts.env
    elseif opts.env then
      getEnv = function(specEnv)
        return vim.tbl_extend("force", opts.env, specEnv)
      end
    end
    if is_callable(opts.cwd) then
      getCwd = opts.cwd
    elseif opts.cwd then
      getCwd = function()
        return opts.cwd
      end
    end
    if is_callable(opts.strategy_config) then
      getStrategyConfig = opts.strategy_config
    elseif opts.strategy_config then
      getStrategyConfig = function()
        return opts.strategy_config
      end
    end
    return adapter
  end,
})

return adapter
