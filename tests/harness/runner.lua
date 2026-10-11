-- Minimal test runner: describe / it / expect, with readable failure messages.

local Runner = {}

local suites = {}
local currentSuite = nil

local function Describe(value, depth)
	depth = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) ~= "table" or depth > 2 then
		return tostring(value)
	end
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for index, key in ipairs(keys) do
		if index > 12 then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = tostring(key) .. "=" .. Describe(value[key], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end
Runner.Describe = Describe

local function DeepEqual(a, b, path)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false, path .. ": expected " .. Describe(b) .. ", got " .. Describe(a)
	end
	for key, value in pairs(b) do
		local ok, why = DeepEqual(a[key], value, path .. "." .. tostring(key))
		if not ok then
			return false, why
		end
	end
	for key in pairs(a) do
		if b[key] == nil then
			return false, path .. "." .. tostring(key) .. ": unexpected value " .. Describe(a[key])
		end
	end
	return true
end
Runner.DeepEqual = DeepEqual

local function Fail(message)
	error(message, 3)
end

-- Matchers take the actual value first; expect() binds it so tests read
-- expect(value).toBe(expected).
local Expectation = {}

function Expectation.toBe(actual, expected)
	if actual ~= expected then
		Fail("expected " .. Describe(expected) .. ", got " .. Describe(actual))
	end
end

function Expectation.toEqual(actual, expected)
	local ok, why = DeepEqual(actual, expected, "value")
	if not ok then
		Fail(why)
	end
end

function Expectation.toBeNil(actual)
	if actual ~= nil then
		Fail("expected nil, got " .. Describe(actual))
	end
end

function Expectation.toBeTruthy(actual)
	if not actual then
		Fail("expected a truthy value, got " .. Describe(actual))
	end
end

function Expectation.toBeFalsy(actual)
	if actual then
		Fail("expected a falsy value, got " .. Describe(actual))
	end
end

function Expectation.toBeCloseTo(actual, expected, tolerance)
	tolerance = tolerance or 1e-6
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		Fail("expected ~" .. tostring(expected) .. ", got " .. Describe(actual))
	end
end

function Expectation.toBeGreaterThan(actual, expected)
	if not (type(actual) == "number" and actual > expected) then
		Fail("expected > " .. tostring(expected) .. ", got " .. Describe(actual))
	end
end

function Expectation.toBeLessThan(actual, expected)
	if not (type(actual) == "number" and actual < expected) then
		Fail("expected < " .. tostring(expected) .. ", got " .. Describe(actual))
	end
end

function Expectation.toHaveLength(actual, expected)
	local length = type(actual) == "string" and #actual or (type(actual) == "table" and #actual)
	if length ~= expected then
		Fail("expected length " .. tostring(expected) .. ", got " .. tostring(length))
	end
end

function Expectation.toContain(actual, expected)
	if type(actual) == "string" then
		if not actual:find(expected, 1, true) then
			Fail("expected " .. Describe(actual) .. " to contain " .. Describe(expected))
		end
		return
	end
	for _, value in pairs(actual or {}) do
		if value == expected then
			return
		end
	end
	Fail("expected " .. Describe(actual) .. " to contain " .. Describe(expected))
end

function Expectation.toMatch(actual, pattern)
	if type(actual) ~= "string" or not actual:find(pattern) then
		Fail("expected " .. Describe(actual) .. " to match " .. pattern)
	end
end

function Expectation.toThrow(actual, pattern)
	local ok, err = pcall(actual)
	if ok then
		Fail("expected function to throw")
	end
	if pattern and not tostring(err):find(pattern) then
		Fail("expected error matching " .. pattern .. ", got " .. tostring(err))
	end
end

function Expectation.notToThrow(actual)
	local ok, err = pcall(actual)
	if not ok then
		Fail("expected no error, got " .. tostring(err))
	end
end

function Runner.expect(actual)
	local bound = {}
	for name, matcher in pairs(Expectation) do
		bound[name] = function(...)
			return matcher(actual, ...)
		end
	end
	return bound
end

function Runner.describe(name, body)
	local suite = { name = name, tests = {} }
	suites[#suites + 1] = suite
	local previous = currentSuite
	currentSuite = suite
	body()
	currentSuite = previous
end

function Runner.it(name, body)
	assert(currentSuite, "it() must be called inside describe()")
	currentSuite.tests[#currentSuite.tests + 1] = { name = name, body = body }
end

--- Runs every registered test; returns the number of failures.
function Runner.Run(filter)
	local passed, failed = 0, 0
	for _, suite in ipairs(suites) do
		for _, test in ipairs(suite.tests) do
			local fullName = suite.name .. " > " .. test.name
			if not filter or fullName:find(filter, 1, true) then
				local ok, err = xpcall(test.body, function(message)
					return debug.traceback(tostring(message), 2)
				end)
				if ok then
					passed = passed + 1
				else
					failed = failed + 1
					io.write("\27[31mFAIL\27[0m ", fullName, "\n    ", (tostring(err):gsub("\n", "\n    ")), "\n")
				end
			end
		end
	end
	local color = failed == 0 and "\27[32m" or "\27[31m"
	io.write(color, string.format("%d passed, %d failed", passed, failed), "\27[0m\n")
	return failed
end

return Runner
