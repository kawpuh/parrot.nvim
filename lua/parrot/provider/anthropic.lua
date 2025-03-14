local logger = require("parrot.logger")
local utils = require("parrot.utils")
local Job = require("plenary.job")

---@class Anthropic
---@field endpoint string
---@field api_key string|table
---@field name string
local Anthropic = {}
Anthropic.__index = Anthropic

-- Available API parameters for Anthropic
-- https://docs.anthropic.com/en/api/messages
local AVAILABLE_API_PARAMETERS = {
  -- required
  model = true,
  messages = true,
  max_tokens = true,
  -- optional
  metadata = true,
  stop_sequences = true,
  stream = true,
  system = true,
  temperature = true,
  thinking = {
    budget_tokens = true,
    type = true,
  },
  tool_choice = true,
  tools = true,
  top_k = true,
  top_p = true,
}

-- Creates a new Anthropic instance
---@param endpoint string
---@param api_key string|table
---@return Anthropic
function Anthropic:new(endpoint, api_key)
  return setmetatable({
    endpoint = endpoint,
    api_key = api_key,
    name = "anthropic",
    _thinking_buf = nil,
    _thinking_win = nil,
    _thinking_output = "",
  }, self)
end

-- Placeholder for setting model (not implemented)
function Anthropic:set_model(_) end

-- Preprocesses the payload before sending to the API
---@param payload table
---@return table
function Anthropic:preprocess_payload(payload)
  for _, message in ipairs(payload.messages) do
    message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
  end
  if payload.messages[1] and payload.messages[1].role == "system" then
    -- remove the first message that serves as the system prompt as anthropic
    -- expects the system prompt to be part of the API call body and not the messages
    payload.system = payload.messages[1].content
    table.remove(payload.messages, 1)
  end
  local params = utils.filter_payload_parameters(AVAILABLE_API_PARAMETERS, payload)
  return params
end

-- Returns the curl parameters for the API request
---@return table
function Anthropic:curl_params()
  return {
    self.endpoint,
    "-H",
    "x-api-key: " .. self.api_key,
    "-H",
    "anthropic-version: 2023-06-01",
  }
end

-- Verifies the API key or executes a routine to retrieve it
---@return boolean
function Anthropic:verify()
  if type(self.api_key) == "table" then
    local command = table.concat(self.api_key, " ")
    local handle = io.popen(command)
    if handle then
      self.api_key = handle:read("*a"):gsub("%s+", "")
      handle:close()
      return true
    else
      logger.error("Error verifying API key of " .. self.name)
      return false
    end
  elseif self.api_key and self.api_key:match("%S") then
    return true
  else
    logger.error("Error with API key " .. self.name .. " " .. vim.inspect(self.api_key))
    return false
  end
end

-- Notification system: displays thinking tokens in a floating window in the top right.
-- The buffer is created with text wrapping enabled, and tokens are accumulated into one coherent string.
function Anthropic:notify_thinking(thinking)
  vim.schedule(function()
    if not self._thinking_buf or not vim.api.nvim_buf_is_valid(self._thinking_buf) then
      self._thinking_buf = vim.api.nvim_create_buf(false, true) -- unlisted scratch buffer
      local width = math.floor(vim.o.columns * 0.3)
      local height = math.floor(vim.o.lines * 0.3)
      local row = 0
      local col = vim.o.columns - width
      self._thinking_win = vim.api.nvim_open_win(self._thinking_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
      })
      vim.api.nvim_buf_set_option(self._thinking_buf, "buftype", "nofile")
      vim.api.nvim_win_set_option(self._thinking_win, "wrap", true)
      self._thinking_output = ""
    end

    -- Accumulate tokens into one coherent string.
    self._thinking_output = self._thinking_output .. thinking
    local lines = vim.split(self._thinking_output, "\n", {})
    vim.api.nvim_buf_set_lines(self._thinking_buf, 0, -1, false, lines)
  end)
end

-- Processes the stdout from the API response.
-- For "text_delta" responses, returns the text.
-- For "thinking_delta" responses, streams tokens to the floating window.
---@param response string
---@return string|nil
function Anthropic:process_stdout(response)
  local success, decoded_line = pcall(vim.json.decode, response)
  if not success then
    logger.debug("Could not decode response: " .. response)
    return nil
  end

  if decoded_line.delta then
    if decoded_line.delta.type == "text_delta" and decoded_line.delta.text then
      return decoded_line.delta.text
    elseif decoded_line.delta.type == "thinking_delta" and decoded_line.delta.thinking then
      self:notify_thinking(decoded_line.delta.thinking)
      return nil
    end
  end

  logger.debug("Could not process response: " .. response)
  return nil
end

-- Processes the onexit event from the API response
---@param res string
function Anthropic:process_onexit(res)
  local success, parsed = pcall(vim.json.decode, res)
  if success and parsed.error and parsed.error.message then
    logger.error(string.format("Anthropic - message: %s type: %s", parsed.error.message, parsed.error.type))
  end
end

-- Returns the list of available models
---@return string[]
function Anthropic:get_available_models(online)
  local ids = {
    "claude-3-7-sonnet-20250219",
    "claude-3-5-sonnet-20241022",
    "claude-3-5-haiku-20241022",
    "claude-3-5-sonnet-20240620",
    "claude-3-haiku-20240307",
    "claude-3-opus-20240229",
    "claude-3-sonnet-20240229",
    "claude-2.1",
    "claude-2.0",
  }

  if online and self:verify() then
    local job = Job:new({
      command = "curl",
      args = {
        "https://api.anthropic.com/v1/models",
        "-H",
        "x-api-key: " .. self.api_key,
        "-H",
        "anthropic-version: 2023-06-01",
      },
      on_exit = function(job)
        local parsed_response = utils.parse_raw_response(job:result())
        self:process_onexit(parsed_response)
        ids = {}
        local success, decoded = pcall(vim.json.decode, parsed_response)
        if success and decoded.data then
          for _, item in ipairs(decoded.data) do
            table.insert(ids, item.id)
          end
        end
        return ids
      end,
    })
    job:start()
    job:wait()
  end
  return ids
end

return Anthropic
