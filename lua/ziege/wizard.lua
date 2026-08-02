local M = {}

local function choice_value(choice)
  if type(choice) == "table" then
    if choice.value ~= nil then
      return choice.value
    end
    return choice.id
  end
  return choice
end

function M.ask(questions, callback)
  local answers = {}
  local index = 1
  local ui = require("ziege.config").get().ui

  local function next_question()
    local question = questions[index]
    index = index + 1
    if not question then
      callback(answers)
      return
    elseif type(question.id) ~= "string" or question.id == "" then
      vim.notify("[ziege] Creation questions require an id", vim.log.levels.ERROR)
      callback(nil)
      return
    end

    if question.kind == "input" then
      ui.input({
        prompt = question.prompt or question.id,
        default = question.default,
      }, function(value)
        if value == nil then
          callback(nil)
          return
        end
        answers[question.id] = value
        next_question()
      end)
      return
    end

    local choices = question.choices
    if question.kind == "confirm" and not choices then
      choices = {
        { label = "Yes", value = true },
        { label = "No", value = false },
      }
    end
    if (question.kind ~= "select" and question.kind ~= "confirm") or type(choices) ~= "table" then
      vim.notify(
        string.format("[ziege] Unsupported creation question '%s'", question.kind),
        vim.log.levels.ERROR
      )
      callback(nil)
      return
    end
    ui.select(choices, {
      prompt = question.prompt or question.id,
      format_item = function(choice)
        return type(choice) == "table" and (choice.label or tostring(choice_value(choice)))
          or tostring(choice)
      end,
    }, function(choice)
      if choice == nil then
        callback(nil)
        return
      end
      answers[question.id] = choice_value(choice)
      next_question()
    end)
  end

  next_question()
end

return M
