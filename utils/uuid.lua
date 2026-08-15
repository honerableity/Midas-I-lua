local bit = require('bit')

local tohex = bit.tohex
local band = bit.band
local bor = bit.bor
local fmt = string.format
local random = math.random

local M = {}

function M.generate_v4()
  return fmt('%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s',
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),

    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),

    tohex(bor(band(random(0, 255), 0x0F), 0x40), 2),
    tohex(random(0, 255), 2),

    tohex(bor(band(random(0, 255), 0x3F), 0x80), 2),
    tohex(random(0, 255), 2),

    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2),
    tohex(random(0, 255), 2))
end

function M.is_valid(str)
  if type(str) ~= 'string' or #str ~= 36 then return false end
  local d = '[0-9a-fA-F]'
  local p = '^' .. table.concat({
    d:rep(8), d:rep(4), d:rep(4), '[89ab]' .. d:rep(3), d:rep(12)
  }, '%-') .. '$'
  return str:match(p) ~= nil
end

return setmetatable(M, { __call = M.generate_v4 })
