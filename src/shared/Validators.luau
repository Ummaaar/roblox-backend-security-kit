--!strict
--[[
	Validators
	----------
	Tiny, dependency-free runtime type checking for anything that crosses the
	client -> server boundary (RemoteEvent / RemoteFunction arguments).

	Rule of thumb: every value sent by a client is attacker-controlled.
	Check its type, its range and its shape BEFORE any game logic touches it.

	Each validator is a function `(value) -> (ok, reason?)`.

	Example:
		local V = require(Shared.Validators)
		local checkItemId = V.string({ maxLength = 32, pattern = "^[%w_]+$" })
		local ok, reason = checkItemId(itemId)
]]

export type Check = (value: any) -> (boolean, string?)

local Validators = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Finite number (rejects NaN and +/-inf, which break comparisons and DataStores).
type NumberOptions = { min: number?, max: number?, integer: boolean? }
type StringOptions = { minLength: number?, maxLength: number?, pattern: string? }

function Validators.number(opts: NumberOptions?): Check
	local o: NumberOptions = opts or {} :: NumberOptions
	local min, max, integer = o.min, o.max, o.integer == true
	return function(value: any): (boolean, string?)
		if not isFiniteNumber(value) then
			return false, "expected finite number"
		end
		if integer and value % 1 ~= 0 then
			return false, "expected integer"
		end
		if min ~= nil and value < min then
			return false, `below min {min}`
		end
		if max ~= nil and value > max then
			return false, `above max {max}`
		end
		return true, nil
	end
end

--- String with byte-length limits, valid UTF-8 and an optional Lua pattern.
function Validators.string(opts: StringOptions?): Check
	local o: StringOptions = opts or {} :: StringOptions
	local maxLength: number = o.maxLength or 256 -- never accept unbounded strings
	local minLength, pattern = o.minLength, o.pattern
	return function(value: any): (boolean, string?)
		if type(value) ~= "string" then
			return false, "expected string"
		end
		if #value > maxLength then
			return false, `string longer than {maxLength} bytes`
		end
		if minLength ~= nil and #value < minLength then
			return false, `string shorter than {minLength} bytes`
		end
		if utf8.len(value) == nil then
			return false, "invalid utf-8"
		end
		if pattern ~= nil and string.match(value, pattern) == nil then
			return false, "string does not match pattern"
		end
		return true, nil
	end
end

function Validators.boolean(): Check
	return function(value: any): (boolean, string?)
		if type(value) ~= "boolean" then
			return false, "expected boolean"
		end
		return true, nil
	end
end

--- Value must be one of the given literals (strings, numbers, booleans).
function Validators.oneOf(...: any): Check
	local allowed = {}
	for _, literal in { ... } do
		allowed[literal] = true
	end
	return function(value: any): (boolean, string?)
		if value == nil or allowed[value] ~= true then
			return false, "value not in allowed set"
		end
		return true, nil
	end
end

--- Value must be a key of the given dictionary (e.g. a server-side catalog).
function Validators.keyOf(dictionary: { [any]: any }): Check
	return function(value: any): (boolean, string?)
		if value == nil or dictionary[value] == nil then
			return false, "unknown key"
		end
		return true, nil
	end
end

function Validators.optional(check: Check): Check
	return function(value: any): (boolean, string?)
		if value == nil then
			return true, nil
		end
		return check(value)
	end
end

--- Roblox Instance of a given class. Clients can pass ANY instance they can see,
--- so always re-check ownership/position on the server after this.
function Validators.instanceIsA(className: string): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "Instance" then
			return false, "expected Instance"
		end
		if not (value :: any):IsA(className) then
			return false, `expected {className}`
		end
		return true, nil
	end
end

--- Array (sequential table 1..n) where each element passes `check`.
function Validators.array(check: Check, opts: { maxLength: number? }?): Check
	local maxLength = (opts and opts.maxLength) or 100
	return function(value: any): (boolean, string?)
		if type(value) ~= "table" then
			return false, "expected array"
		end
		local count = 0
		for key in value do
			count += 1
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				return false, "array has non-sequential keys"
			end
		end
		if count > maxLength then
			return false, `array longer than {maxLength}`
		end
		for i = 1, count do
			if value[i] == nil then
				return false, "array has holes"
			end
			local ok, reason = check(value[i])
			if not ok then
				return false, `[{i}] {reason}`
			end
		end
		return true, nil
	end
end

--- Dictionary with an exact shape: unknown keys are rejected.
function Validators.strictTable(shape: { [string]: Check }): Check
	return function(value: any): (boolean, string?)
		if type(value) ~= "table" then
			return false, "expected table"
		end
		for key in value do
			if type(key) ~= "string" or shape[key] == nil then
				return false, `unexpected key {tostring(key)}`
			end
		end
		for key, check in shape do
			local ok, reason = check(value[key])
			if not ok then
				return false, `.{key}: {reason}`
			end
		end
		return true, nil
	end
end

--[[
	Validates a full argument list. Arity is exact: extra arguments are a
	violation (exploit scripts often probe remotes with garbage payloads).

	`args` must come from `table.pack(...)` so that `args.n` is reliable
	even when some arguments are nil.
]]
function Validators.arguments(checks: { Check }, args: { n: number, [number]: any }): (boolean, string?)
	if args.n > #checks then
		return false, `expected at most {#checks} arguments, got {args.n}`
	end
	for i, check in checks do
		local ok, reason = check(args[i])
		if not ok then
			return false, `arg #{i}: {reason}`
		end
	end
	return true, nil
end

return Validators
