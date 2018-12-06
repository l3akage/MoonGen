
standalone = true
master = "dummy"

local moongen       = require "moongen"
local memory        = require "memory"
local device        = require "device"
local ts            = require "timestamping"
local filter        = require "filter"
local ffi           = require "ffi"
local barrier       = require "barrier"
local arp           = require "proto.arp"
local hist          = require "histogram"
local timer         = require "timer"
local utils         = require "rfc2544.utils.utils"

local UDP_PORT = 42

local benchmark = {}
benchmark.__index = benchmark

function benchmark.create()
    local self = setmetatable({}, benchmark)
    self.initialized = false
    return self
end
setmetatable(benchmark, {__call = benchmark.create})

function benchmark:init(arg)
    self.duration = arg.duration or 10

    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues

    self.skipConf = arg.skipConf
    self.dut = arg.dut

    self.initialized = true
end

function benchmark:config()
    self.undoStack = {}
    utils.addInterfaceIP(self.dut.ifIn, "198.18.1.1", 24)
    table.insert(self.undoStack, {foo = utils.delInterfaceIP, args = {self.dut.ifIn, "198.18.1.1", 24}})

    utils.addInterfaceIP(self.dut.ifOut, "198.19.1.1", 24)
    table.insert(self.undoStack, {foo = utils.delInterfaceIP, args = {self.dut.ifOut, "198.19.1.1", 24}})
end

function benchmark:undoConfig()
    local len = #self.undoStack
    for k, v in ipairs(self.undoStack) do
        --work in stack order
        local elem = self.undoStack[len - k + 1]
        elem.foo(unpack(elem.args))
    end
    --clear stack
    self.undoStack = {}
end

function benchmark:getCSVHeader()
    return "latency,packet,frame size,rate,duration"
end

function benchmark:resultToCSV(result)
    local str = ""
    result:calc()
    for k ,v in ipairs(result.sortedHisto) do
            str = str .. v.k .. "," .. v.v .. "," .. result.frameSize .. "," .. result.rate .. "," .. self.duration
        if result.sortedHisto[k+1] then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:bench(frameSize, rate)
    if not self.initialized then
        return print("benchmark not initialized");
    elseif frameSize == nil then
        return error("benchmark got invalid frameSize");
    end

    if not self.skipConf then
        self:config()
    end

    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    local bar = barrier:new(0)
    local port = UDP_PORT

    -- workaround for rate bug
    local numQueues = rate > (64 * 64) / (84 * 84) * maxLinkRate and rate < maxLinkRate and 3 or 1
    bar:reinit(numQueues + 1)
    if rate < maxLinkRate then
        -- not maxLinkRate
        -- eventual multiple slaves
        -- set rate is payload rate not wire rate
        for i=1, numQueues do
            printf("set queue %i to rate %d", i, rate * frameSize / (frameSize + 20) / numQueues)
            self.txQueues[i]:setRate(rate * frameSize / (frameSize + 20) / numQueues)
        end
    else
        -- maxLinkRate
        self.txQueues[1]:setRate(rate)
    end

    -- traffic generator
    local loadSlaves = {}
    for i=1, numQueues do
        table.insert(loadSlaves, moongen.startTask("latencyLoadSlave", self.txQueues[i], port, frameSize, self.duration, mod, bar))
    end

    local hist = latencyTimerSlave(self.txQueues[numQueues+1], self.rxQueues[1], port, frameSize, self.duration, bar)
    hist:print()

    local spkts = 0
    for _, sl in pairs(loadSlaves) do
        spkts = spkts + sl:wait()
    end

    if not self.skipConf then
        self:undoConfig()
    end
    hist.frameSize = frameSize
    hist.rate = spkts / 10^6 / self.duration
    return hist
end

function latencyLoadSlave(queue, port, frameSize, duration, modifier, bar)
    local ethDst = arp.blockingLookup("198.18.1.1", 10)
    --TODO: error on timeout

    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            ip4Dst = "198.19.1.2",
            ip4Src = "198.18.1.2",
            udpSrc = SRC_PORT,
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    local bufs = mem:bufArray()
    --local modifierFoo = utils.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)

    -- TODO: RFC2544 routing updates if router
    -- send learning frames:
    --      ARP for IP

    local sendBufs = function(bufs, port)
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
            -- apply modifier like ip or mac randomisation to packet
--          modifierFoo(pkt)
        end
        -- send packets
        bufs:offloadUdpChecksums()
        return queue:send(bufs)
    end
    -- warmup phase to wake up card
    local t = timer:new(0.1)
    while t:running() do
        sendBufs(bufs, port + 1)
    end


    -- sync with timerSlave
    bar:wait()

    -- benchmark phase
    local totalSent = 0
    t:reset(duration + 2)
    while t:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end

function latencyTimerSlave(txQueue, rxQueue, port, frameSize, duration, bar)
    --Timestamped packets must be > 80 bytes (+4crc)
    frameSize = frameSize > 84 and frameSize or 84

    local ethDst = arp.blockingLookup("198.18.1.1", 10)
    --TODO: error on timeout

    local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
    local hist = hist:new()
    local rateLimit = timer:new(0.001)

    -- sync with load slave and wait additional few milliseconds to ensure
    -- the traffic generator has started
    bar:wait()
    moongen.sleepMillis(1000)

    local t = timer:new(duration)
    while t:running() do
        hist:update(timestamper:measureLatency(frameSize - 4, function(buf)
            local pkt = buf:getUdpPacket()
            pkt:fill({
                -- TODO: timestamp on different IPs
                ethSrc = txQueue,
                ethDst = ethDst,
                ip4Src = "198.18.1.2",
                ip4Dst = "198.19.1.2",
                udpSrc = SRC_PORT,
                udpDst = port,
                pktLength = frameSize - 4
            })
        end))
        rateLimit:wait()
        rateLimit:reset()
    end
    return hist
end

function configure(parser)
	parser:description("RFC2544 Latency test")
	parser:argument("txport", "Device to transmit from."):convert(tonumber)
    parser:argument("rxport", "Device to receive from."):convert(tonumber)
    parser:option("-r --rate", "Rate"):convert(tonumber)
    parser:option("-d --duration", "Duration. Default: 10"):default(10):convert(tonumber)
    parser:option("-f --file", "CSV Filename. Default: latency.csv"):default("latency.csv")
    return parser:parse()
end

function master(args)
    local txPort, rxPort = args.txport, args.rxport
    local rxDev, txDev
    if txPort == rxPort then
        -- sending and receiving from the same port
        txDev = device.config({port = txPort, rxQueues = 3, txQueues = 5})
        rxDev = txDev
    else
        -- two different ports, different configuration
        txDev = device.config({port = txPort, rxQueues = 2, txQueues = 5})
        rxDev = device.config({port = rxPort, rxQueues = 3, txQueues = 1})
    end
    device.waitForLinks()
    if txPort == rxPort then
        moongen.startTask(arp.arpTask, {
            {
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(1),
                ips = {"198.18.1.2", "198.19.1.2", "198.18.1.1"}
            }
        })
    else
        moongen.startTask(arp.arpTask, {
            {
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(1),
                ips = {"198.18.1.2"}
            },
            {
                txQueue = rxDev:getTxQueue(0),
                rxQueue = rxDev:getRxQueue(1),
                ips = {"198.19.1.2", "198.18.1.1", "198.18.1.1"}
            }
        })
    end

    local bench = benchmark()
    bench:init({
        txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3), txDev:getTxQueue(4)},
        rxQueues = {rxDev:getRxQueue(2)},
        duration = args.duration,
        skipConf = true,
    })

    local results = {}
    local FRAME_SIZES   = {64, 128, 256, 512, 1024, 1280, 1518, 1596, 1700}
    for _, frameSize in ipairs(FRAME_SIZES) do
        local result = bench:bench(frameSize, args.rate or 5000)
        -- save and report results
        table.insert(results, result)
    end

    file = io.open(args.file, "w")
    file:write(bench:getCSVHeader(), "\n")
    for _,result in ipairs(results) do
        file:write(bench:resultToCSV(result), "\n")
    end
    file:close()
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
