local function Quest(questID, counts, state)
	local quest = { questID = questID, objectives = {}, complete = state == "c", failed = state == "f" }
	for index = 1, #counts, 2 do
		quest.objectives[#quest.objectives + 1] = { fulfilled = counts[index], required = counts[index + 1] }
	end
	return quest
end

describe("Protocol", function()
	it("encodes a quest as ID, state and counts", function()
		local _, ns = Harness.Load()
		local Protocol = ns.Protocol
		expect(Protocol.EncodeRecord(Quest(100, { 2, 6, 10, 10 }))).toBe("100,-,2/6,10/10")
		expect(Protocol.EncodeRecord(Quest(101, { 6, 6 }, "c"))).toBe("101,c,6/6")
		expect(Protocol.EncodeRecord(Quest(102, {}, "f"))).toBe("102,f")
	end)

	it("round-trips every message type", function()
		local _, ns = Harness.Load()
		local Protocol = ns.Protocol
		local hello = Protocol.Parse(Protocol.Hello("0.1.0"))
		expect(hello).toEqual({ kind = "H", version = 1, addonVersion = "0.1.0" })

		local full = Protocol.Full("a1", { "100,-,2/6", "101,c" })
		expect(full).toEqual({ "F1:a1:1:1:100,-,2/6;101,c" })
		expect(Protocol.Parse(full[1])).toEqual({
			kind = "F",
			version = 1,
			syncId = "a1",
			part = 1,
			total = 1,
			records = {
				{ questID = 100, state = "-", counts = { 2, 6 } },
				{ questID = 101, state = "c", counts = {} },
			},
		})

		local delta = Protocol.Delta({ "100,-,3/6" })
		expect(Protocol.Parse(delta[1]).records[1].counts).toEqual({ 3, 6 })
		expect(Protocol.Parse(Protocol.Removed({ 100, 101 })[1]).ids).toEqual({ 100, 101 })
		expect(Protocol.Parse(Protocol.Push(100)).questID).toBe(100)
	end)

	it("sends an empty full state as one message that clears the receiver", function()
		local _, ns = Harness.Load()
		local messages = ns.Protocol.Full("b2", {})
		expect(messages).toEqual({ "F1:b2:1:1:" })
		expect(ns.Protocol.Parse(messages[1]).records).toEqual({})
	end)

	it("splits a large state into parts that each fit in one message", function()
		local _, ns = Harness.Load()
		local Protocol = ns.Protocol
		local records = {}
		for index = 1, 35 do
			records[index] = Protocol.EncodeRecord(Quest(100000 + index, { 12, 15, 3, 10, 0, 1 }))
		end
		local messages = Protocol.Full("c3", records)
		expect(#messages > 1).toBe(true)
		local seen = 0
		for part, text in ipairs(messages) do
			expect(#text <= 255).toBe(true)
			local message = Protocol.Parse(text)
			expect(message.part).toBe(part)
			expect(message.total).toBe(#messages)
			seen = seen + #message.records
		end
		expect(seen).toBe(35)
	end)

	it("never claims more parts than it sends", function()
		local _, ns = Harness.Load()
		local Protocol = ns.Protocol
		local records = {}
		for index = 1, 600 do
			records[index] = Protocol.EncodeRecord(Quest(1000000 + index, { 1, 2 }))
		end
		local messages = Protocol.Full("d4", records)
		expect(#messages).toBe(Protocol.MAX_PARTS)
		local last = Protocol.Parse(messages[#messages])
		expect({ last.part, last.total }).toEqual({ Protocol.MAX_PARTS, Protocol.MAX_PARTS })
	end)

	it("keeps a quest with very many objectives within one message", function()
		local _, ns = Harness.Load()
		local counts = {}
		for _ = 1, 30 do
			counts[#counts + 1] = 99999
			counts[#counts + 1] = 99999
		end
		local record = ns.Protocol.EncodeRecord(Quest(9999999, counts))
		local message = ns.Protocol.Delta({ record })[1]
		expect(#message <= 255).toBe(true)
		expect(ns.Protocol.Parse(message)).toBeTruthy()
	end)

	it("rejects malformed messages", function()
		local _, ns = Harness.Load()
		local Parse = ns.Protocol.Parse
		for _, text in ipairs({
			"",
			"hello",
			"Q1:100",
			"D1:",
			"D1:abc,-",
			"D1:100,z,1/2",
			"D1:100,-,1/",
			"D1:0,-",
			"D1:100,-,1/2;",
			"F1:x:2:1:",
			"F1:x:0:1:",
			"F1:x:1:21:",
			"F1:waytoolongid:1:1:",
			"X1:",
			"X1:1,,2",
			"P1:abc",
			"H1:bad version!",
			"H0:1.0",
			string.rep("D1:100,-,1/2;", 30),
		}) do
			expect(Parse(text)).toBeNil()
		end
	end)

	it("recognizes a newer protocol without reading it", function()
		local _, ns = Harness.Load()
		expect(ns.Protocol.Parse("D2:whatever;format")).toEqual({ kind = "D", version = 2, newer = true })
	end)

	it("strips characters that don't belong in a version", function()
		local _, ns = Harness.Load()
		expect(ns.Protocol.Hello("v1.2 beta:3")).toBe("H1:v1.2beta3")
		expect(ns.Protocol.Hello("")).toBe("H1:dev")
	end)
end)
