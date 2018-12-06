
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
local timer         = require "timer"
local namespaces    = require "namespaces"
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
    self.granularity = arg.granularity or 100
    self.duration = arg.duration or 2
    self.numIterations = arg.numIterations or 50

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
    local str = "frameSize,precision,linkspeed,duration"
    for iteration=1, self.numIterations do
        str = str .. ",burstsize iter" .. iteration
    end
    return str
end

function benchmark:resultToCSV(result)
    str = result.frameSize .. "," .. self.granularity .. "," .. self.txQueues[1].dev:getLinkStatus().speed .. "," .. self.duration .. "s"
    for iteration=1, self.numIterations do
        str = str .. "," .. result[iteration]
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

    local port = UDP_PORT
    local bar = barrier:new(2)
    local results = {frameSize = frameSize}


    for iteration=1, self.numIterations do
        printf("starting iteration %d for frame size %d", iteration, frameSize)

        local loadSlave = moongen.startTask("backtobackLoadSlave", self.txQueues[1], frameSize, nil, bar, self.granularity, self.duration)
        local counterSlave = moongen.startTask("backtobackCounterSlave", self.rxQueues[1], frameSize, bar, self.granularity, self.duration)

        local longestS = loadSlave:wait()
        local longestR = counterSlave:wait()

        if longest ~= loadSlave:wait() then
            printf("WARNING: loadSlave and counterSlave reported different burst sizes (sender=%d, receiver=%d)", longestS, longestR)
            results[iteration] = -1
        else
            results[iteration] = longestS
            printf("iteration %d: longest burst: %d", iteration, longestS)
        end
    end

    if not self.skipConf then
        self:undoConfig()
    end

    return results
end

local rsns = namespaces.get()

function sendBurst(numPkts, mem, queue, size, port, modFoo)
    local sent = 0
    local bufs = mem:bufArray(64)
    local stop = numPkts - (numPkts % 64)
    while moongen.running() and sent < stop do
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
        end
        bufs:offloadUdpChecksums()
        sent = sent + queue:send(bufs)

    end
    if numPkts ~= stop then
        bufs = mem:bufArray(numPkts % 64)
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
        end
        bufs:offloadUdpChecksums()
        sent = sent + queue:send(bufs)
    end
    return sent
end

function backtobackLoadSlave(queue, frameSize, modifier, bar, granularity, duration)
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
            -- does not affect performance, as self fill is done before any packet is sent
            ip4Src = "198.18.1.2",
            ip4Dst = "198.19.1.2",
            udpSrc = UDP_PORT,
            -- udpSrc will be set later as it varies
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    --wait for counter slave
    bar:wait()
    --TODO: dirty workaround for resetting a barrier
    moongen.sleepMicros(100)
    bar:reinit(2)

    local linkSpeed = queue.dev:getLinkStatus().speed
    local maxPkts = math.ceil((linkSpeed * 10^6 / ((frameSize + 20) * 8)) * duration) -- theoretical max packets send in about `duration` seconds with linkspeed
    local count = maxPkts
    local longest = 0
    local binSearch = utils.binarySearch(0, maxPkts)
    local first = true


    while moongen.running() do
        local t = timer.new(0.5)
        queue:setRate(10)
        while t:running() do
            sendBurst(64, mem, queue, frameSize - 4, UDP_PORT+1)
        end
        queue:setRate(linkSpeed)

        local sent = sendBurst(count, mem, queue, frameSize - 4, UDP_PORT)

        rsns.sent = sent

        bar:wait()
        --TODO: fix barrier reset
        -- reinit interferes with wait
        moongen.sleepMicros(100)
        bar:reinit(2)

        -- do a binary search
        -- throw away firt try
        if first then
           first = false
        else
            local top = sent == rsns.received
            --get next rate
            local nextCount, finished = binSearch:next(count, top, granularity)
            -- update longest
            longest = (top and count) or longest
            if finished then
                break
            end
            printf("loadSlave: sent %d and received %d => changing from %d to %d", sent, rsns.received, count, nextCount)
            count = nextCount
        end
        moongen.sleepMillis(2000)
    end
    return longest
end

function backtobackCounterSlave(queue, frameSize, bar, granularity, duration)

    local bufs = memory.bufArray()

    local maxPkts = math.ceil((queue.dev:getLinkStatus().speed * 10^6 / ((frameSize + 20) * 8)) * duration) -- theoretical max packets send in about `duration` seconds with linkspeed
    local count = maxPkts
    local longest = 0
    local binSearch = utils.binarySearch(0, maxPkts)
    local first = true


    local t = timer:new(0.5)
    while t:running() do
        queue:tryRecv(bufs, 100)
        bufs:freeAll()
    end

    -- wait for sender to be ready
    bar:wait()
    while moongen.running() do
        local timer = timer:new(duration + 2)
        local counter = 0

        while timer:running() do
            rx = queue:tryRecv(bufs, 1000)
            for i = 1, rx do
                local buf = bufs[i]
                local pkt = buf:getUdpPacket()
                if pkt.udp:getDstPort() == UDP_PORT then
                    counter = counter + 1
                end
            end
            bufs:freeAll()
            if counter >= count then
                break
            end
        end
        rsns.received = counter

        -- wait for sender -> both renewed value in rsns
        bar:wait()

        -- do a binary search
        -- throw away firt try
        if first then
            first = false
        else
            local top = counter == rsns.sent
            --get next rate
            local nextCount, finished = binSearch:next(count, top, granularity)
            -- update longest
            longest = (top and count) or longest
            if finished then
                break
            end
            printf("counterSlave: sent %d and received %d => changing from %d to %d", rsns.sent, counter, count, nextCount)
            count = nextCount
        end
        moongen.sleepMillis(2000)
    end
    return longest
end

function configure(parser)
	parser:description("RFC2544 Backtoback test")
	parser:argument("txport", "Device to transmit from."):convert(tonumber)
    parser:argument("rxport", "Device to receive from."):convert(tonumber)
    parser:option("-d --duration", "Duration. Default: 2"):default(2):convert(tonumber)
    parser:option("-n --numiterations", "Numiterations. Default: 50"):default(50):convert(tonumber)
    parser:option("-g --granularity", "Granularity. Default: 50"):default(100):convert(tonumber)
    parser:option("-f --file", "CSV Filename. Default: backtoback.csv"):default("backtoback.csv")
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
        txQueues = {txDev:getTxQueue(1)},
        rxQueues = {rxDev:getRxQueue(0)},
        granularity = 100,
        duration = args.duration,
        numIterations = args.iterations,
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
