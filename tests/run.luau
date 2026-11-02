--[[
	Standalone unit tests for the pure modules (no Roblox APIs needed).
	Run with the Luau CLI from the repository root:

		luau tests/run.luau
]]

local Validators = require("../src/shared/Validators")
local RateLimiter = require("../src/shared/RateLimiter")

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok    {name}`)
	else
		failed += 1
		print(`  FAIL  {name}: {err}`)
	end
end

local function expect(cond: boolean, message: string?)
	if not cond then
		error(message or "expectation failed", 2)
	end
end

print("Validators")

test("number rejects NaN and infinity", function()
	local check = Validators.number()
	expect(not (check(0 / 0)), "NaN accepted")
	expect(not (check(math.huge)), "inf accepted")
	expect(not (check(-math.huge)), "-inf accepted")
	expect((check(42)), "42 rejected")
end)

test("number enforces integer and range", function()
	local check = Validators.number({ min = 1, max = 10, integer = true })
	expect((check(5)), "5 rejected")
	expect(not (check(5.5)), "5.5 accepted")
	expect(not (check(0)), "0 accepted")
	expect(not (check(11)), "11 accepted")
	expect(not (check("5")), "string accepted")
end)

test("string enforces length, utf-8 and pattern", function()
	local check = Validators.string({ maxLength = 8, pattern = "^[%w_]+$" })
	expect((check("Sword_1")), "valid id rejected")
	expect(not (check("this_is_too_long")), "long string accepted")
	expect(not (check("bad id!")), "pattern bypassed")
	expect(not (check("\255\254")), "invalid utf-8 accepted")
	expect(not (check(nil)), "nil accepted")
end)

test("string has a default max length", function()
	local check = Validators.string()
	expect(not (check(string.rep("a", 10000))), "unbounded string accepted")
end)

test("keyOf only accepts catalog keys", function()
	local check = Validators.keyOf({ WoodenSword = true })
	expect((check("WoodenSword")), "valid key rejected")
	expect(not (check("AdminSword")), "unknown key accepted")
	expect(not (check(nil)), "nil accepted")
end)

test("optional allows nil only", function()
	local check = Validators.optional(Validators.boolean())
	expect((check(nil)), "nil rejected")
	expect((check(true)), "true rejected")
	expect(not (check("true")), "string accepted")
end)

test("array rejects holes, non-sequential keys and oversize", function()
	local check = Validators.array(Validators.number(), { maxLength = 3 })
	expect((check({ 1, 2, 3 })), "valid array rejected")
	expect(not (check({ 1, 2, 3, 4 })), "oversized array accepted")
	expect(not (check({ [1] = 1, [3] = 3 })), "holey array accepted")
	expect(not (check({ a = 1 })), "dictionary accepted")
	expect(not (check({ 1, "x" })), "bad element accepted")
end)

test("strictTable rejects unknown keys", function()
	local check = Validators.strictTable({ itemId = Validators.string(), amount = Validators.number({ min = 1 }) })
	expect((check({ itemId = "Potion", amount = 2 })), "valid table rejected")
	expect(not (check({ itemId = "Potion", amount = 2, price = 0 })), "injected key accepted")
	expect(not (check({ itemId = "Potion" })), "missing key accepted")
end)

test("arguments enforces arity", function()
	local checks = { Validators.string(), Validators.number() }
	expect((Validators.arguments(checks, table.pack("a", 1))), "valid args rejected")
	expect(not (Validators.arguments(checks, table.pack("a", 1, "extra"))), "extra arg accepted")
	expect(not (Validators.arguments(checks, table.pack("a"))), "missing arg accepted")
end)

print("RateLimiter")

test("allows a burst up to capacity then blocks", function()
	local now = 0
	local limiter = RateLimiter.new(3, 1, function()
		return now
	end)
	expect(limiter:consume("p"), "1st blocked")
	expect(limiter:consume("p"), "2nd blocked")
	expect(limiter:consume("p"), "3rd blocked")
	expect(not limiter:consume("p"), "4th allowed")
end)

test("refills over time and caps at capacity", function()
	local now = 0
	local limiter = RateLimiter.new(2, 1, function()
		return now
	end)
	limiter:consume("p")
	limiter:consume("p")
	expect(not limiter:consume("p"), "empty bucket allowed")
	now = 1
	expect(limiter:consume("p"), "refill not applied")
	now = 100
	expect(limiter:consume("p"), "refill lower than capacity (1)")
	expect(limiter:consume("p"), "refill lower than capacity (2)")
	expect(not limiter:consume("p"), "refill above capacity")
end)

test("keys are independent and reset works", function()
	local now = 0
	local limiter = RateLimiter.new(1, 0, function()
		return now
	end)
	expect(limiter:consume("a"), "a blocked")
	expect(limiter:consume("b"), "b blocked by a")
	expect(not limiter:consume("a"), "a allowed twice")
	limiter:reset("a")
	expect(limiter:consume("a"), "reset ignored")
end)

print(`\n{passed} passed, {failed} failed`)
if failed > 0 then
	error("tests failed")
end
