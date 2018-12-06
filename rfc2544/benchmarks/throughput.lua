
standalone = true
master = "dummy"

local moongen       = require "moongen"
local memory        = require "memory"
local device        = require "device"
local filter        = require "filter"
local ffi           = require "ffi"
local barrier       = require "barrier"
local timer         = require "timer"
local utils         = require "rfc2544.utils.utils"
local arp           = require "proto.arp"

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
    self.rateThreshold = arg.rateThreshold or 10
    self.maxLossRate = arg.maxLossRate or 0.001

    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues

    self.numIterations = arg.numIterations or 1

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
    local str = "frame size(byte),duration(s),max loss rate(%),rate threshold(packets)"
    for i=1, self.numIterations do
        str = str .. "," .. "rate(mpps) iter" .. i .. ",spkts(byte) iter" .. i .. ",rpkts(byte) iter" .. i
    end
    return str
end

function benchmark:resultToCSV(result)
    local str = ""
    for i=1, self.numIterations do
        str = str .. result[i].frameSize .. "," .. self.duration .. "," .. self.maxLossRate * 100 .. "," .. self.rateThreshold .. "," .. result[i].mpps .. "," .. result[i].spkts .. "," .. result[i].rpkts
        if i < self.numIterations then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:bench(frameSize)
    if not self.initialized then
        return print("benchmark not initialized");
    elseif frameSize == nil then
        return error("benchmark got invalid frameSize");
    end

    if not self.skipConf then
        self:config()
    end

    local binSearch = utils.binarySearch()
    local pktLost = true
    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    local rate, lastRate
    local bar = barrier:new(2)
    local results = {}
    local rateSum = 0
    local finished = false

    --repeat the test for statistical purpose
    for iteration=1,self.numIterations do
        local port = UDP_PORT
        binSearch:init(0, maxLinkRate)
        rate = maxLinkRate -- start at maximum, so theres a chance at reaching maximum (otherwise only maximum - threshold can be reached)
        lastRate = rate

        printf("starting iteration %d for frameSize %d", iteration, frameSize)
        --init maximal transfer rate without packetloss of this iteration to zero
        results[iteration] = {spkts = 0, rpkts = 0, mpps = 0, frameSize = frameSize}
        -- loop until no packetloss
        while moongen.running() do

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

            local loadTasks = {}
            -- traffic generator
            for i=1, numQueues do
                table.insert(loadTasks, moongen.startTask("throughputLoadSlave", self.txQueues[i], port, frameSize, self.duration, mod, bar))
            end

            -- count the incoming packets
            local ctrTask = moongen.startTask("throughputCounterSlave", self.rxQueues[1], port, frameSize, self.duration, bar)

            -- wait until all slaves are finished
            local spkts = 0
            for _, loadTask in pairs(loadTasks) do
                spkts = spkts + loadTask:wait()
            end
            local rpkts = ctrTask:wait()

            local lossRate = (spkts - rpkts) / spkts
            local validRun = lossRate <= self.maxLossRate
            if validRun then
                -- theres a minimal gap between self.duration and the real measured duration, but that
                -- doesnt matter
                results[iteration] = { spkts = spkts, rpkts = rpkts, mpps = spkts / 10^6 / self.duration, frameSize = frameSize}
            end

            printf("sent %d packets, received %d", spkts, rpkts)
            printf("rate %f and packetloss %f => %d", rate, lossRate, validRun and 1 or 0)

            lastRate = rate
            rate, finished = binSearch:next(rate, validRun, self.rateThreshold)
            if finished then
                -- not setting rate in table as it is not guaranteed that last round all
                -- packets were received properly
                local mpps = results[iteration].mpps
                printf("maximal rate for packetsize %d: %0.2f Mpps, %0.2f MBit/s, %0.2f MBit/s wire rate", frameSize, mpps, mpps * frameSize * 8, mpps * (frameSize + 20) * 8)
                rateSum = rateSum + results[iteration].mpps
                break
            end

            printf("changing rate from %d MBit/s to %d MBit/s", lastRate, rate)
            -- TODO: maybe wait for resettlement of DUT (RFC2544)
            port = port + 1
	        moongen.sleepMillis(100)
        --device.reclaimTxBuffers()
        end
    end

    if not self.skipConf then
        self:undoConfig()
    end

    return results, rateSum / self.numIterations
end

function throughputLoadSlave(queue, port, frameSize, duration, modifier, bar)
    local ethDst = arp.blockingLookup("198.18.1.1", 10)
    --TODO: error on timeout

    --wait for counter slave
    bar:wait()

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
            -- TODO: too slow with conditional -- eventual launch a second slave for self
            -- ethDst SHOULD be in 1% of the frames the hardware broadcast address
            -- for switches ethDst also SHOULD be randomized

            -- if ipDest is dynamical created it is overwritten
            -- does not affect performance, as self fill is done before any packet is sent
            ip4Src = "198.18.1.2",
            ip4Dst = "198.19.1.2",
            udpSrc = UDP_PORT,
            -- udpSrc will be set later as it varies
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
    local timer = timer:new(0.1)
    while timer:running() do
        sendBufs(bufs, port - 1)
    end

    -- benchmark phase
    timer:reset(duration)
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end

function throughputCounterSlave(queue, port, frameSize, duration, bar)
    local bufs = memory.bufArray()
    local stats = {}
    bar:wait()

    local timer = timer:new(duration + 3)
    while timer:running() do
        local rx = queue:tryRecv(bufs, 1000)
        for i = 1, rx do
            local buf = bufs[i]
            local pkt = buf:getUdpPacket()
            local port = pkt.udp:getDstPort()
            stats[port] = (stats[port] or 0) + 1
        end
        bufs:freeAll()
    end
    return stats[port] or 0
end

function configure(parser)
	parser:description("RFC2544 Throughput test")
	parser:argument("txport", "Device to transmit from."):convert(tonumber)
    parser:argument("rxport", "Device to receive from."):convert(tonumber)
    parser:option("-d --duration", "Duration. Default: 10"):default(10):convert(tonumber)
    parser:option("-n --numiterations", "Numiterations. Default: 1"):default(1):convert(tonumber)
    parser:option("-f --file", "CSV Filename. Default: throughput.csv"):default("throughput.csv")
    return parser:parse()
end

function master(args)
    local txPort, rxPort = args.txport, args.rxport
    local rxDev, txDev
    if txPort == rxPort then
        -- sending and receiving from the same port
        txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4})
        rxDev = txDev
    else
        -- two different ports, different configuration
        txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4})
        rxDev = device.config({port = rxPort, rxQueues = 2, txQueues = 3})
    end
    device.waitForLinks()
    if txPort == rxPort then
        moongen.startTask(arp.arpTask, {
            {
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(1),
                ips = {"198.18.1.2", "198.19.1.2"}
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
                ips = {"198.19.1.2", "198.18.1.1"}
            }
        })
    end

    local bench = benchmark()
    bench:init({
        txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3)},
        rxQueues = {rxDev:getRxQueue(0)},
        duration = args.duration,
        numIterations = args.numiterations,
        skipConf = true,
    })

    local results = {}
    local FRAME_SIZES   = {64, 128, 256, 512, 1024, 1280, 1518, 1596, 1700}
    for _, frameSize in ipairs(FRAME_SIZES) do
        local result = bench:bench(frameSize)
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
