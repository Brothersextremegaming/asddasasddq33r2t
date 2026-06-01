-- ===== Unload any previous execution =====
-- The UI library is a singleton via getgenv().Library / getgenv().Esp.
-- When the script is re-run after closing the GUI, leftover globals from
-- the prior run collide with the new load ("Esp:Create missing"). Clear
-- them first so each execution starts from a clean slate.
if getgenv then
    pcall(function()
        if getgenv().Esp and getgenv().Esp.Unload then
            getgenv().Esp.Unload()
        end
    end)
    pcall(function() getgenv().Esp = nil end)
    pcall(function()
        if getgenv().Library and getgenv().Library.Unload then
            getgenv().Library:Unload()
        end
    end)
    pcall(function()
        getgenv().Library = nil
        getgenv().Options = nil
    end)
    task.wait(0.3)
end

local Players          = game:GetService("Players")
local HttpService      = game:GetService("HttpService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- ─────────────────────────────────────────────
--  CONFIG
-- ─────────────────────────────────────────────
local FIREBASE_PROJECT = "studio-9760542617-d373c"
local SESSION_FILE     = "execsync_session.txt"
local DISCORD_INVITE   = "https://discord.gg/execsync"
local LIBRARY_URL      = "https://raw.githubusercontent.com/opdyno10/Modified-UI-Library/refs/heads/main/library.lua"
local DELIVERY_SESSION_ATTRIBUTE = "ExecSyncDeliverySession"

pcall(function()
    PlayerGui:SetAttribute(DELIVERY_SESSION_ATTRIBUTE, "")
end)

-- Black & white palette applied to every theme key.
local BW_THEME = {
    ["Background"]     = Color3.fromRGB(12, 12, 12),
    ["Inline"]        = Color3.fromRGB(20, 20, 20),
    ["Shadow"]        = Color3.fromRGB(0, 0, 0),
    ["Text"]          = Color3.fromRGB(255, 255, 255),
    ["Image"]         = Color3.fromRGB(255, 255, 255),
    ["Dark Gradient"] = Color3.fromRGB(170, 170, 170),
    ["Inactive Text"] = Color3.fromRGB(135, 135, 135),
    ["Element"]       = Color3.fromRGB(28, 28, 28),
    ["Accent"]        = Color3.fromRGB(255, 255, 255),
    ["Border"]        = Color3.fromRGB(42, 42, 42),
}

local function applyBWTheme(lib)
    pcall(function()
        for Key, Color in pairs(BW_THEME) do
            if lib.Theme then lib.Theme[Key] = Color end
            lib:ChangeTheme(Key, Color)
        end
    end)
end

local FIRESTORE_BASE = "https://firestore.googleapis.com/v1/projects/"
    .. FIREBASE_PROJECT .. "/databases/(default)/documents"
local QUERY_URL = FIRESTORE_BASE .. ":runQuery"

-- ─────────────────────────────────────────────
--  UNIVERSAL HTTP WRAPPER
-- ─────────────────────────────────────────────
local function rawRequest(opts)
    if type(request) == "function" then
        return request(opts)
    elseif type(http) == "table" and type(http.request) == "function" then
        return http.request(opts)
    elseif type(http_request) == "function" then
        return http_request(opts)
    else
        return HttpService:RequestAsync(opts)
    end
end

-- ─────────────────────────────────────────────
--  THROTTLED HTTP QUEUE
-- ─────────────────────────────────────────────
-- On autoload, presence + logs + GUI-build logs all fired their own
-- task.spawn(request) at once, flooding the executor's HTTP layer and
-- crashing the game. Everything now goes through ONE worker that runs a
-- single request at a time with a small gap between them.
local HTTP_GAP   = 0.2   -- seconds between consecutive requests
local HttpQueue  = {}
local QueueAwake = false

local function startHttpWorker()
    if QueueAwake then return end
    QueueAwake = true

    task.spawn(function()
        while true do
            local job = table.remove(HttpQueue, 1)
            if not job then
                QueueAwake = false
                return
            end

            local ok, res = pcall(rawRequest, job.opts)

            if job.resolve then
                job.resolve(ok, res)
            end

            task.wait(HTTP_GAP)
        end
    end)
end

-- Fire-and-forget: enqueue and return immediately (used for logs/presence).
local function queueRequest(opts)
    table.insert(HttpQueue, { opts = opts })
    startHttpWorker()
end

-- Blocking: enqueue and yield until the worker runs it. Returns the same
-- shape as the raw request (or nil + error string on failure).
local function httpRequest(opts)
    local thread = coroutine.running()
    local done = false

    table.insert(HttpQueue, {
        opts = opts,
        resolve = function(ok, res)
            done = true
            task.spawn(thread, ok, res)
        end,
    })
    startHttpWorker()

    local ok, res = coroutine.yield()
    if not ok then
        error(res, 0)
    end
    return res
end

-- ─────────────────────────────────────────────
--  NOTIFICATION HELPER
-- ─────────────────────────────────────────────
local ActiveLib  = nil
local NotifQueue = {}

local function notify(title, body, duration)
    duration = duration or 5
    if ActiveLib and ActiveLib.Notification then
        ActiveLib:Notification({
            Name        = title,
            Description = body,
            Duration    = duration,
            Icon        = "116339777575852",
            IconColor   = Color3.fromRGB(255, 255, 255),
        })
    else
        table.insert(NotifQueue, { title, body, duration })
        warn("[ExecSync] " .. title .. " — " .. body)
    end
end

local function flushNotifQueue()
    for _, n in ipairs(NotifQueue) do
        ActiveLib:Notification({
            Name        = n[1],
            Description = n[2],
            Duration    = n[3],
            Icon        = "116339777575852",
            IconColor   = Color3.fromRGB(255, 255, 255),
        })
    end
    NotifQueue = {}
end

-- ─────────────────────────────────────────────
--  REMOTE LOGGER
-- ─────────────────────────────────────────────
local function remoteLog(level, message)
    -- Fire-and-forget through the throttled queue (no per-call spawn).
    queueRequest({
        Url     = FIRESTORE_BASE .. "/debugLogs",
        Method  = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = HttpService:JSONEncode({
            fields = {
                        username  = { stringValue  = LocalPlayer.Name },
                        level     = { stringValue  = level },
                        message   = { stringValue  = tostring(message) },
                        timestamp = { integerValue = tostring(os.time()) },
                placeId   = { stringValue  = tostring(game.PlaceId) },
                jobId     = { stringValue  = tostring(game.JobId) },
            }
        }),
    })
end
local function logInfo(m)  remoteLog("INFO",  m) end
local function logWarn(m)  remoteLog("WARN",  m) end
local function logError(m) remoteLog("ERROR", m) end

-- ─────────────────────────────────────────────
--  LIVE SESSION TELEMETRY
-- ─────────────────────────────────────────────
-- Pushes live game stats to userStats/{username} so the dashboard can
-- monitor the session remotely. Toggled by "Live Telemetry" in Misc.
local TelemetryEnabled = false        -- user opt-in for the stats push
local SessionStart     = os.time()    -- for elapsed-time reporting

-- Formats a second count as e.g. "1h 04m 09s".
local function formatElapsed(seconds)
    seconds = math.max(0, math.floor(seconds))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%dh %02dm %02ds", h, m, s)
    elseif m > 0 then
        return string.format("%dm %02ds", m, s)
    end
    return string.format("%ds", s)
end

-- Gathers the values the dashboard wants to show. displayName and elapsed
-- are fully implemented (pure Roblox / script state). money, team and car
-- are GAME-SPECIFIC: Driving Empire stores them in its own leaderstats /
-- character / data modules, which differ per game. Fill in each stub with
-- the correct path for Driving Empire and the rest of the pipeline works
-- unchanged.
local function gatherGameStats()
    local displayName = LocalPlayer.DisplayName
    local elapsed     = os.time() - SessionStart

    -- ── Money (GAME-SPECIFIC) ─────────────────
    -- Example for a leaderstats-based game:
    --   local ls = LocalPlayer:FindFirstChild("leaderstats")
    --   money = ls and ls:FindFirstChild("Cash") and ls.Cash.Value
    local money = 0
    pcall(function()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        if ls then
            local cash = ls:FindFirstChild("Cash")
                or ls:FindFirstChild("Money")
                or ls:FindFirstChild("Bank")
            if cash then money = cash.Value end
        end
    end)

    -- ── Team (GAME-SPECIFIC) ──────────────────
    -- Driving Empire's Police/Civilian state isn't a true Roblox Team for
    -- everyone; fall back to the Team object if present.
    local team = "Unknown"
    pcall(function()
        if LocalPlayer.Team then team = LocalPlayer.Team.Name end
    end)

    -- ── Car (GAME-SPECIFIC) ───────────────────
    -- Best-effort: the seated vehicle's model name. Replace with Driving
    -- Empire's own "current vehicle" lookup for an exact match.
    local car = "None"
    pcall(function()
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.SeatPart then
            local v = hum.SeatPart:FindFirstAncestorOfClass("Model")
            if v then car = v.Name end
        end
    end)

    return {
        displayName = displayName,
        team        = team,
        car         = car,
        money       = money,
        elapsed     = elapsed,
    }
end

-- PATCHes the current stats to userStats/{username}. Respects both the
-- master No-Telemetry kill switch and the per-feature Live Telemetry opt-in.
local function pushUserStats(username)
    -- Gated by the explicit Live Telemetry opt-in. (The Misc "No Telemetry"
    -- toggle, when present, also turns this off via TelemetryEnabled.)
    if not TelemetryEnabled then return end

    local stats = gatherGameStats()
    queueRequest({
        Url     = FIRESTORE_BASE .. "/userStats/" .. tostring(username),
        Method  = "PATCH",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = HttpService:JSONEncode({
            fields = {
                username    = { stringValue  = tostring(username) },
                displayName = { stringValue  = tostring(stats.displayName) },
                team        = { stringValue  = tostring(stats.team) },
                car         = { stringValue  = tostring(stats.car) },
                money       = { integerValue = tostring(math.floor(stats.money)) },
                elapsed     = { integerValue = tostring(stats.elapsed) },
                elapsedText = { stringValue  = formatElapsed(stats.elapsed) },
                lastUpdated = { integerValue = tostring(os.time()) },
            }
        }),
    })
end

-- Starts the 60s push loop. Safe to call once; only pushes while the
-- Live Telemetry toggle is on (pushUserStats self-gates).
local function startStatsLoop(username)
    task.spawn(function()
        while true do
            task.wait(60)
            if not LocalPlayer or not LocalPlayer:IsDescendantOf(game) then break end
            pcall(pushUserStats, username)
        end
    end)
end

-- ─────────────────────────────────────────────
--  CLIENT-SIDE DELIVERY AUTO FARM
-- ─────────────────────────────────────────────
local DELIVERY_CONFIG = {
    TeamName = "Delivery Driver",
    JobName = "Delivery",
    JobPadName = "jobPad",

    EffectsFolderName = "DeliveryLocationEffects",
    RingName = "Ring",
    LocationInstanceName = "DeliveryLocation",
    PickupItemsFolderName = "DeliveryPickupItems_DeliveryLocation",

    TeleportYOffset = 4,
    TeleportRetryCount = 5,
    TeleportRetryDelay = 0.12,
    TeleportArriveTolerance = 25,

    PollDelay = 0.2,
    JobRequestRetryDelay = 3,
    InteractDelay = 0.35,
    LocationInstanceWaitTime = 8,
    LocationInstanceMaxDistance = 260,
    BoxSpawnGraceTime = 2,
    TargetChangeTimeout = 8,
    StateCFrameFreshTime = 120,

    PreferStateCFrameOverRing = true,
    RequireStateCFrameAfterStuds = 1100,

    FireDeliveryCompletedOnDropoff = true,
    DeliveryCompletedAttempts = 3,
    DeliveryCompletedRetryDelay = 0.25,
}

local DeliveryRuntime = nil

local function waitForDeliveryRemote(parent, name, timeout)
    local remote = parent and parent:FindFirstChild(name)
    if remote then
        return remote
    end

    if parent then
        return parent:WaitForChild(name, timeout or 10)
    end

    return nil
end

local function findDeliveryStateChanged(remotes)
    return (remotes and (
        remotes:FindFirstChild("DeliveryStateChanged")
        or remotes:FindFirstChild("deliveryStateChanged")
    ))
        or ReplicatedStorage:FindFirstChild("DeliveryStateChanged")
        or ReplicatedStorage:FindFirstChild("deliveryStateChanged")
end

local function getDeliveryRemotes()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
        or ReplicatedStorage:WaitForChild("Remotes", 10)

    if not remotes then
        return nil, "Remotes folder was not found."
    end

    local requestStartJobSession = waitForDeliveryRemote(remotes, "RequestStartJobSession", 10)
    local deliveryLocationInteracted = waitForDeliveryRemote(remotes, "DeliveryLocationInteracted", 10)

    if not requestStartJobSession then
        return nil, "RequestStartJobSession remote was not found."
    end

    if not deliveryLocationInteracted then
        return nil, "DeliveryLocationInteracted remote was not found."
    end

    return {
        RequestStartJobSession = requestStartJobSession,
        DeliveryLocationInteracted = deliveryLocationInteracted,
        DeliveryCompleted = remotes:FindFirstChild("DeliveryCompleted"),
        DeliveryStateChanged = findDeliveryStateChanged(remotes),
    }
end

local function isDeliveryRuntimeActive(runtime)
    if not runtime or not runtime.Running or DeliveryRuntime ~= runtime then
        return false
    end

    if not LocalPlayer or not LocalPlayer:IsDescendantOf(game) then
        return false
    end

    local ok, sessionId = pcall(function()
        return PlayerGui:GetAttribute(DELIVERY_SESSION_ATTRIBUTE)
    end)

    return ok and sessionId == runtime.SessionId
end

local function disconnectDeliveryState(runtime)
    if runtime and runtime.StateConnection then
        pcall(function()
            runtime.StateConnection:Disconnect()
        end)
        runtime.StateConnection = nil
    end
end

local function stopDeliveryAutoFarm(silent)
    local runtime = DeliveryRuntime
    if not runtime then
        return
    end

    runtime.Running = false
    disconnectDeliveryState(runtime)

    if DeliveryRuntime == runtime then
        DeliveryRuntime = nil
    end

    pcall(function()
        if PlayerGui:GetAttribute(DELIVERY_SESSION_ATTRIBUTE) == runtime.SessionId then
            PlayerGui:SetAttribute(DELIVERY_SESSION_ATTRIBUTE, "")
        end
    end)

    if not silent then
        notify("ExecSync", "Auto Delivery stopped.", 3)
        logInfo("Auto Delivery stopped")
    end
end

local function toDeliveryCFrame(value)
    local valueType = typeof(value)

    if valueType == "CFrame" then
        return value
    elseif valueType == "Vector3" then
        return CFrame.new(value)
    elseif valueType == "Instance" then
        if value:IsA("BasePart") then
            return value.CFrame
        elseif value:IsA("Attachment") then
            return value.WorldCFrame
        elseif value:IsA("Model") then
            return value:GetPivot()
        elseif value:IsA("CFrameValue") then
            return value.Value
        elseif value:IsA("Vector3Value") then
            return CFrame.new(value.Value)
        end
    elseif valueType == "table" then
        local x = value.X or value.x
        local y = value.Y or value.y
        local z = value.Z or value.z

        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return CFrame.new(x, y, z)
        end

        return toDeliveryCFrame(value.CFrame)
            or toDeliveryCFrame(value.cframe)
            or toDeliveryCFrame(value.TargetCFrame)
            or toDeliveryCFrame(value.targetCFrame)
            or toDeliveryCFrame(value.LocationCFrame)
            or toDeliveryCFrame(value.locationCFrame)
            or toDeliveryCFrame(value.DropoffCFrame)
            or toDeliveryCFrame(value.dropoffCFrame)
            or toDeliveryCFrame(value.DestinationCFrame)
            or toDeliveryCFrame(value.destinationCFrame)
            or toDeliveryCFrame(value.Position)
            or toDeliveryCFrame(value.position)
            or toDeliveryCFrame(value.TargetPosition)
            or toDeliveryCFrame(value.targetPosition)
            or toDeliveryCFrame(value.DropoffPosition)
            or toDeliveryCFrame(value.dropoffPosition)
            or toDeliveryCFrame(value.DestinationPosition)
            or toDeliveryCFrame(value.destinationPosition)
    end

    return nil
end

local function findDeliveryCFrameDeep(value, depth, seen)
    depth = depth or 0
    if depth > 8 then
        return nil
    end

    local ok, cframe = pcall(toDeliveryCFrame, value)
    if ok and cframe then
        return cframe
    end

    if typeof(value) ~= "table" then
        return nil
    end

    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true

    for key, childValue in pairs(value) do
        cframe = findDeliveryCFrameDeep(childValue, depth + 1, seen)
            or findDeliveryCFrameDeep(key, depth + 1, seen)

        if cframe then
            return cframe
        end
    end

    return nil
end

local function rememberDeliveryStateCFrame(runtime, ...)
    for index = 1, select("#", ...) do
        local cframe = findDeliveryCFrameDeep(select(index, ...))
        if cframe then
            runtime.LastStateCFrame = cframe
            runtime.LastStateCFrameAt = os.clock()
            return true
        end
    end

    return false
end

local function connectDeliveryStateChanged(runtime)
    local deliveryStateChanged = runtime.Remotes.DeliveryStateChanged
    if not deliveryStateChanged then
        return
    end

    if deliveryStateChanged:IsA("RemoteEvent") then
        runtime.StateConnection = deliveryStateChanged.OnClientEvent:Connect(function(...)
            rememberDeliveryStateCFrame(runtime, ...)
        end)
    elseif deliveryStateChanged:IsA("BindableEvent") then
        runtime.StateConnection = deliveryStateChanged.Event:Connect(function(...)
            rememberDeliveryStateCFrame(runtime, ...)
        end)
    end
end

local function fireDeliveryRemote(remote, ...)
    if not remote then
        return false
    end

    local args = table.pack(...)

    if remote:IsA("RemoteEvent") then
        remote:FireServer(table.unpack(args, 1, args.n))
        return true
    elseif remote:IsA("RemoteFunction") then
        task.spawn(function()
            pcall(function()
                remote:InvokeServer(table.unpack(args, 1, args.n))
            end)
        end)
        return true
    end

    return false
end

local function isDeliveryDriver()
    return LocalPlayer.Team and LocalPlayer.Team.Name == DELIVERY_CONFIG.TeamName
end

local function ensureDeliveryJob(runtime)
    local lastRequest = 0

    while isDeliveryRuntimeActive(runtime) and not isDeliveryDriver() do
        local now = os.clock()

        if now - lastRequest >= DELIVERY_CONFIG.JobRequestRetryDelay then
            fireDeliveryRemote(
                runtime.Remotes.RequestStartJobSession,
                DELIVERY_CONFIG.JobName,
                DELIVERY_CONFIG.JobPadName
            )
            lastRequest = now
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end

    return isDeliveryDriver()
end

local function getDeliveryCharacterRoot(runtime)
    while isDeliveryRuntimeActive(runtime) do
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")

        if character and root then
            return character, root
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end

    return nil, nil
end

local function normalizeDeliveryCharacter(character, root)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if humanoid then
        humanoid.Sit = false
        humanoid.PlatformStand = false
        humanoid.AutoRotate = true

        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end

    if character then
        for _, descendant in ipairs(character:GetDescendants()) do
            if descendant:IsA("BasePart") then
                descendant.Anchored = false
                descendant.AssemblyLinearVelocity = Vector3.zero
                descendant.AssemblyAngularVelocity = Vector3.zero
            end
        end
    elseif root then
        root.Anchored = false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    return humanoid
end

local function cframeFromDeliveryRingInstance(ring)
    if not ring then
        return nil
    end

    local cframe = toDeliveryCFrame(ring)
    if cframe then
        return cframe
    end

    for _, descendant in ipairs(ring:GetDescendants()) do
        cframe = toDeliveryCFrame(descendant)
        if cframe then
            return cframe
        end
    end

    return nil
end

local function getDeliveryRootPosition()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    return root and root.Position or nil
end

local function isFreshDeliveryStateCFrame(runtime)
    return runtime.LastStateCFrame ~= nil
        and os.clock() - runtime.LastStateCFrameAt <= DELIVERY_CONFIG.StateCFrameFreshTime
end

local function deliveryCFramesClose(first, second)
    if not first or not second then
        return false
    end

    return (first.Position - second.Position).Magnitude <= 6
end

local function clearDeliveryStateCFrameIfSame(runtime, cframe)
    if deliveryCFramesClose(runtime.LastStateCFrame, cframe) then
        runtime.LastStateCFrame = nil
        runtime.LastStateCFrameAt = 0
    end
end

local function findCurrentDeliveryRing()
    local effectsFolder = Workspace:FindFirstChild(DELIVERY_CONFIG.EffectsFolderName)
    if not effectsFolder then
        return nil
    end

    local directRing = effectsFolder:FindFirstChild(DELIVERY_CONFIG.RingName)
    if directRing then
        return directRing
    end

    for _, descendant in ipairs(effectsFolder:GetDescendants()) do
        if descendant.Name == DELIVERY_CONFIG.RingName then
            return descendant
        end
    end

    return nil
end

local function addDeliveryLocationCandidate(candidates, seen, instance)
    if instance and not seen[instance] then
        seen[instance] = true
        table.insert(candidates, instance)
    end
end

local function collectDeliveryLocationCandidates()
    local candidates = {}
    local seen = {}
    local ring = findCurrentDeliveryRing()
    local effectsFolder = Workspace:FindFirstChild(DELIVERY_CONFIG.EffectsFolderName)

    if ring then
        local current = ring
        while current and current ~= Workspace do
            if current.Name == DELIVERY_CONFIG.LocationInstanceName then
                addDeliveryLocationCandidate(candidates, seen, current)
            end

            current = current.Parent
        end
    end

    if effectsFolder then
        addDeliveryLocationCandidate(
            candidates,
            seen,
            effectsFolder:FindFirstChild(DELIVERY_CONFIG.LocationInstanceName)
        )

        for _, descendant in ipairs(effectsFolder:GetDescendants()) do
            if descendant.Name == DELIVERY_CONFIG.LocationInstanceName then
                addDeliveryLocationCandidate(candidates, seen, descendant)
            end
        end
    end

    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant.Name == DELIVERY_CONFIG.LocationInstanceName then
            addDeliveryLocationCandidate(candidates, seen, descendant)
        end
    end

    return candidates
end

local function deliveryDistanceFromCFrame(instance, cframe)
    local instanceCFrame = cframeFromDeliveryRingInstance(instance)

    if not instanceCFrame or not cframe then
        return nil
    end

    return (instanceCFrame.Position - cframe.Position).Magnitude
end

local function findDeliveryLocationInstance(targetCFrame)
    local candidates = collectDeliveryLocationCandidates()
    local bestCandidate = nil
    local bestDistance = math.huge
    local fallbackCandidate = nil

    for _, candidate in ipairs(candidates) do
        if candidate.Parent then
            fallbackCandidate = fallbackCandidate or candidate

            local distance = deliveryDistanceFromCFrame(candidate, targetCFrame)
            if distance and distance < bestDistance then
                bestCandidate = candidate
                bestDistance = distance
            end
        end
    end

    if bestCandidate then
        if bestDistance <= DELIVERY_CONFIG.LocationInstanceMaxDistance then
            return bestCandidate
        end

        return nil
    end

    return fallbackCandidate
end

local function waitForDeliveryLocationInstance(runtime, targetCFrame)
    local startedAt = os.clock()

    while isDeliveryRuntimeActive(runtime)
        and os.clock() - startedAt <= DELIVERY_CONFIG.LocationInstanceWaitTime do
        local locationInstance = findDeliveryLocationInstance(targetCFrame)
        if locationInstance then
            return locationInstance
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end

    return findDeliveryLocationInstance(targetCFrame)
end

local function readCurrentDeliveryTargetCFrame(runtime)
    local freshStateCFrame = isFreshDeliveryStateCFrame(runtime) and runtime.LastStateCFrame or nil

    if freshStateCFrame and DELIVERY_CONFIG.PreferStateCFrameOverRing then
        return freshStateCFrame
    end

    local ring = findCurrentDeliveryRing()
    local ringCFrame = cframeFromDeliveryRingInstance(ring)
    local rootPosition = getDeliveryRootPosition()

    if freshStateCFrame and ringCFrame and rootPosition then
        local ringDistance = (ringCFrame.Position - rootPosition).Magnitude

        if ringDistance >= DELIVERY_CONFIG.RequireStateCFrameAfterStuds then
            return freshStateCFrame
        end
    end

    return ringCFrame or freshStateCFrame
end

local function waitForCurrentDeliveryTargetCFrame(runtime)
    while isDeliveryRuntimeActive(runtime) do
        local cframe = readCurrentDeliveryTargetCFrame(runtime)

        if cframe then
            return cframe
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end

    return nil
end

local function setDeliveryCharacterCFrame(runtime, goalCFrame)
    local character, root = getDeliveryCharacterRoot(runtime)
    if not character or not root then
        return false
    end

    normalizeDeliveryCharacter(character, root)

    pcall(function()
        character:PivotTo(goalCFrame)
    end)

    pcall(function()
        root.CFrame = goalCFrame
        root.Anchored = false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)

    normalizeDeliveryCharacter(character, root)

    return true
end

local function moveDeliveryCharacterTo(runtime, targetCFrame)
    local target = targetCFrame + Vector3.new(0, DELIVERY_CONFIG.TeleportYOffset, 0)

    for _ = 1, DELIVERY_CONFIG.TeleportRetryCount do
        if not isDeliveryRuntimeActive(runtime) then
            return false
        end

        if not setDeliveryCharacterCFrame(runtime, target) then
            return false
        end

        task.wait(DELIVERY_CONFIG.TeleportRetryDelay)

        local _, root = getDeliveryCharacterRoot(runtime)
        if root and (root.Position - target.Position).Magnitude <= DELIVERY_CONFIG.TeleportArriveTolerance then
            return true
        end
    end

    return false
end

local function attemptDeliveryCompleted(runtime)
    if not DELIVERY_CONFIG.FireDeliveryCompletedOnDropoff then
        return
    end

    for _ = 1, DELIVERY_CONFIG.DeliveryCompletedAttempts do
        if not isDeliveryRuntimeActive(runtime) then
            return
        end

        fireDeliveryRemote(runtime.Remotes.DeliveryCompleted)
        task.wait(DELIVERY_CONFIG.DeliveryCompletedRetryDelay)
    end
end

local function fireDeliveryLocationInteracted(runtime, locationInstance)
    if locationInstance then
        fireDeliveryRemote(runtime.Remotes.DeliveryLocationInteracted, locationInstance)
    else
        fireDeliveryRemote(runtime.Remotes.DeliveryLocationInteracted)
    end
end

local function getDeliveryPickupItemsFolder()
    return Workspace:FindFirstChild(DELIVERY_CONFIG.PickupItemsFolderName)
end

local function anyDeliveryPickupItemsStillExist()
    local folder = getDeliveryPickupItemsFolder()
    if not folder then
        return false
    end

    for _, item in ipairs(folder:GetChildren()) do
        if item.Parent == folder then
            return true
        end
    end

    return false
end

local function waitForDeliveryPickupItemsDeleted(runtime)
    local startedAt = os.clock()
    local sawItems = anyDeliveryPickupItemsStillExist()

    while isDeliveryRuntimeActive(runtime) do
        local itemsExist = anyDeliveryPickupItemsStillExist()

        if itemsExist then
            sawItems = true
        elseif sawItems then
            return true
        elseif os.clock() - startedAt >= DELIVERY_CONFIG.BoxSpawnGraceTime then
            return true
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end

    return false
end

local function deliverySameSpot(first, second)
    return deliveryCFramesClose(first, second)
end

local function waitForDeliveryTargetChange(runtime, previousCFrame)
    local startedAt = os.clock()

    while isDeliveryRuntimeActive(runtime)
        and os.clock() - startedAt < DELIVERY_CONFIG.TargetChangeTimeout do
        local currentCFrame = readCurrentDeliveryTargetCFrame(runtime)

        if currentCFrame and not deliverySameSpot(currentCFrame, previousCFrame) then
            return true
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end

    return false
end

local function interactAtCurrentDeliveryTarget(runtime, isDropoff)
    local targetCFrame = waitForCurrentDeliveryTargetCFrame(runtime)
    if not targetCFrame then
        return nil
    end

    if not moveDeliveryCharacterTo(runtime, targetCFrame) then
        return nil
    end

    task.wait(DELIVERY_CONFIG.InteractDelay)
    local locationInstance = waitForDeliveryLocationInstance(runtime, targetCFrame)

    clearDeliveryStateCFrameIfSame(runtime, targetCFrame)
    fireDeliveryLocationInteracted(runtime, locationInstance)

    if isDropoff then
        attemptDeliveryCompleted(runtime)
    end

    return targetCFrame, locationInstance
end

local function runDeliveryAutoFarm(runtime)
    while isDeliveryRuntimeActive(runtime) do
        if ensureDeliveryJob(runtime) then
            local pickupCFrame = interactAtCurrentDeliveryTarget(runtime, false)

            if pickupCFrame then
                waitForDeliveryPickupItemsDeleted(runtime)

                local dropoffCFrame = interactAtCurrentDeliveryTarget(runtime, true)

                if dropoffCFrame then
                    waitForDeliveryTargetChange(runtime, dropoffCFrame)
                end
            end
        end

        task.wait(DELIVERY_CONFIG.PollDelay)
    end
end

local function startDeliveryAutoFarm()
    if isDeliveryRuntimeActive(DeliveryRuntime) then
        return true
    end

    local remotes, remoteError = getDeliveryRemotes()
    if not remotes then
        notify("ExecSync", "Auto Delivery could not start: " .. tostring(remoteError), 5)
        logWarn("Auto Delivery failed to start: " .. tostring(remoteError))
        return false
    end

    stopDeliveryAutoFarm(true)

    local runtime = {
        Running = true,
        SessionId = tostring(os.clock()) .. ":" .. tostring(math.random(100000, 999999)),
        Remotes = remotes,
        LastStateCFrame = nil,
        LastStateCFrameAt = 0,
        StateConnection = nil,
    }

    DeliveryRuntime = runtime
    PlayerGui:SetAttribute(DELIVERY_SESSION_ATTRIBUTE, runtime.SessionId)
    connectDeliveryStateChanged(runtime)

    task.spawn(function()
        local ok, err = pcall(runDeliveryAutoFarm, runtime)
        if not ok and isDeliveryRuntimeActive(runtime) then
            notify("ExecSync", "Auto Delivery stopped after an error.", 5)
            logError("Auto Delivery error: " .. tostring(err))
        end

        if DeliveryRuntime == runtime then
            stopDeliveryAutoFarm(true)
        end
    end)

    notify("ExecSync", "Auto Delivery started.", 3)
    logInfo("Auto Delivery started")
    return true
end

-- -------------------------------------------------------------------------
--  TOKEN GENERATOR
-- -------------------------------------------------------------------------
local function generateToken()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local token = ""
    math.randomseed(os.time() * math.random(1000, 9999))
    for _ = 1, 32 do
        local i = math.random(1, #chars)
        token = token .. chars:sub(i, i)
    end
    return token
end

-- ─────────────────────────────────────────────
--  PRESENCE TRACKING
-- ─────────────────────────────────────────────
-- The presence doc must follow the SESSION username, not LocalPlayer.Name.
-- Token logins resolve to an AdoptedUser that can differ from the local
-- Roblox player, and the dashboard watches the session username. We default
-- to LocalPlayer.Name and rebind once the session username is known.
local presenceUser   = LocalPlayer.Name
local presenceDocUrl = FIRESTORE_BASE .. "/userPresence/" .. presenceUser

local function setPresenceUser(username)
    if username and username ~= "" then
        presenceUser   = username
        presenceDocUrl = FIRESTORE_BASE .. "/userPresence/" .. username
    end
end

local function updatePresence(online)
    local fields = {
        username     = { stringValue  = presenceUser },
        online       = { booleanValue = online },
        lastUpdated  = { integerValue = tostring(os.time()) },
        placeId      = { stringValue  = tostring(game.PlaceId) },
        jobId        = { stringValue  = tostring(game.JobId) },
    }

    if online then
        fields.gameUrl = { stringValue =
            "https://www.roblox.com/games/" .. tostring(game.PlaceId) }
        fields.serverLink = { stringValue =
            "roblox://experiences/start?placeId=" .. tostring(game.PlaceId)
            .. "&gameInstanceId=" .. tostring(game.JobId) }
    end

    -- Fire-and-forget through the throttled queue.
    queueRequest({
        Url    = presenceDocUrl
            .. "?updateMask.fieldPaths=username"
            .. "&updateMask.fieldPaths=online"
            .. "&updateMask.fieldPaths=lastUpdated"
            .. "&updateMask.fieldPaths=placeId"
            .. "&updateMask.fieldPaths=jobId"
            .. "&updateMask.fieldPaths=gameUrl"
            .. "&updateMask.fieldPaths=serverLink",
        Method  = "PATCH",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = HttpService:JSONEncode({ fields = fields }),
    })
end

local function goOnline(username)
    setPresenceUser(username)
    logInfo("Presence → ONLINE  user=" .. presenceUser
        .. "  placeId=" .. tostring(game.PlaceId))
    updatePresence(true)

    -- Heartbeat: keeps lastUpdated fresh every 30s so three beats fit inside
    -- the dashboard's 90s offline timeout, even if the throttled HTTP queue
    -- delays one. Reads presenceDocUrl live so it always targets the
    -- resolved session user.
    task.spawn(function()
        while true do
            task.wait(30)
            if not LocalPlayer or not LocalPlayer:IsDescendantOf(game) then break end
            pcall(function()
                httpRequest({
                    Url    = presenceDocUrl
                        .. "?updateMask.fieldPaths=lastUpdated"
                        .. "&updateMask.fieldPaths=online",
                    Method  = "PATCH",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body    = HttpService:JSONEncode({
                        fields = {
                            online      = { booleanValue = true },
                            lastUpdated = { integerValue = tostring(os.time()) },
                        }
                    }),
                })
            end)
        end
    end)
end

local offlineSent = false
local function goOffline()
    if offlineSent then return end
    offlineSent = true
    logInfo("Presence → OFFLINE")
    pcall(function()
        httpRequest({
            Url    = presenceDocUrl
                .. "?updateMask.fieldPaths=online"
                .. "&updateMask.fieldPaths=lastUpdated",
            Method  = "PATCH",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode({
                fields = {
                    online      = { booleanValue = false },
                    lastUpdated = { integerValue = tostring(os.time()) },
                }
            }),
        })
    end)
end

-- Most reliable hook for abrupt game-close / executor detach
pcall(function()
    game:BindToClose(goOffline)
end)

-- Fallback: fires when LocalPlayer is removed from the DataModel
LocalPlayer.AncestryChanged:Connect(function()
    if not LocalPlayer:IsDescendantOf(game) then
        goOffline()
    end
end)

-- ─────────────────────────────────────────────
--  FIRESTORE HELPERS
-- ─────────────────────────────────────────────
local function queryByCode(username, code)
    logInfo("queryByCode → " .. username)

    local body = HttpService:JSONEncode({
        structuredQuery = {
            from  = {{ collectionId = "verificationCodes" }},
            where = {
                compositeFilter = {
                    op = "AND",
                    filters = {
                        {
                            fieldFilter = {
                                field = { fieldPath = "username" },
                                op    = "EQUAL",
                                value = { stringValue = username },
                            }
                        },
                        {
                            fieldFilter = {
                                field = { fieldPath = "code" },
                                op    = "EQUAL",
                                value = { stringValue = tostring(code) },
                            }
                        },
                    }
                }
            },
            limit = 1,
        }
    })

    local ok, res = pcall(function()
        return httpRequest({
            Url     = QUERY_URL,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = body,
        })
    end)

    if not ok then
        local msg = "Network error — check HttpService is enabled."
        logError("queryByCode: " .. tostring(res))
        return nil, msg
    end

    if res.StatusCode ~= 200 then
        local msg = "Firestore error (" .. tostring(res.StatusCode) .. ")."
        logError("queryByCode HTTP " .. tostring(res.StatusCode) .. " body=" .. tostring(res.Body))
        return nil, msg
    end

    local parsed
    ok, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
    if not ok then
        logError("queryByCode: JSON decode failed — " .. tostring(parsed))
        return nil, "Invalid server response."
    end

    if type(parsed) ~= "table" or not parsed[1] or not parsed[1].document then
        logWarn("queryByCode: no document matched")
        return nil, "Code not found. Double-check your username and code."
    end

    logInfo("queryByCode: match → " .. tostring(parsed[1].document.name))
    return parsed[1].document.name, nil
end

local function writeTokenToDoc(docName, token)
    local patchUrl = "https://firestore.googleapis.com/v1/" .. docName
        .. "?updateMask.fieldPaths=used&updateMask.fieldPaths=sessionToken"

    local ok, res = pcall(function()
        return httpRequest({
            Url     = patchUrl,
            Method  = "PATCH",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode({
                fields = {
                    used         = { booleanValue = true },
                    sessionToken = { stringValue  = token },
                }
            }),
        })
    end)

    if not ok then
        logError("writeTokenToDoc network error: " .. tostring(res))
        return false, "Network error when saving session."
    end

    if res.StatusCode ~= 200 then
        logError("writeTokenToDoc HTTP " .. tostring(res.StatusCode))
        return false, "Could not save session (HTTP " .. tostring(res.StatusCode) .. ")."
    end

    logInfo("writeTokenToDoc: OK")
    return true, nil
end

local function queryByToken(token)
    logInfo("queryByToken: " .. token:sub(1, 8) .. "…")

    local body = HttpService:JSONEncode({
        structuredQuery = {
            from  = {{ collectionId = "verificationCodes" }},
            where = {
                fieldFilter = {
                    field = { fieldPath = "sessionToken" },
                    op    = "EQUAL",
                    value = { stringValue = token },
                }
            },
            limit = 1,
        }
    })

    local ok, res = pcall(function()
        return httpRequest({
            Url     = QUERY_URL,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = body,
        })
    end)

    if not ok or res.StatusCode ~= 200 then
        logError("queryByToken failed: " .. tostring(ok and res.StatusCode or res))
        return nil
    end

    local parsed = HttpService:JSONDecode(res.Body)
    if type(parsed) ~= "table" or not parsed[1] or not parsed[1].document then
        logWarn("queryByToken: token not found")
        return nil
    end

    local fields = parsed[1].document.fields
    if fields and fields.username and fields.username.stringValue then
        logInfo("queryByToken → " .. fields.username.stringValue)
        return fields.username.stringValue
    end
    return nil
end

local function fetchRemoteSettings()
    local ok, res = pcall(function()
        return httpRequest({
            Url     = FIRESTORE_BASE .. "/settings/global",
            Method  = "GET",
            Headers = { ["Content-Type"] = "application/json" },
        })
    end)
    if not ok or res.StatusCode ~= 200 then return nil end
    local parsed = HttpService:JSONDecode(res.Body)
    return parsed and parsed.fields or nil
end

-- ─────────────────────────────────────────────
--  SESSION HELPERS
-- ─────────────────────────────────────────────
local function saveToken(t)
    pcall(function() writefile(SESSION_FILE, t) end)
end

local function readToken()
    local exists = false
    pcall(function() exists = isfile(SESSION_FILE) end)
    if not exists then return nil end
    local t = nil
    pcall(function() t = readfile(SESSION_FILE) end)
    return (t and t ~= "") and t or nil
end

local function deleteSessionFile()
    if not pcall(function() delfile(SESSION_FILE) end) then
        pcall(function() writefile(SESSION_FILE, "") end)
    end
    logInfo("Session file deleted")
end

-- ─────────────────────────────────────────────
--  SETTINGS POLL
-- ─────────────────────────────────────────────
local function startSettingsPoll(ML)
    task.spawn(function()
        while true do
            task.wait(300)
            local s = fetchRemoteSettings()
            if s then
                if s.killSwitch and s.killSwitch.booleanValue == true then
                    logWarn("Kill switch activated")
                    notify("ExecSync", "Script disabled remotely.", 6)
                    task.wait(3)
                    stopDeliveryAutoFarm(true)
                    goOffline()
                    ML:Unload()
                    return
                end
                if s.maintenanceMessage and s.maintenanceMessage.stringValue ~= "" then
                    notify("ExecSync – Notice", s.maintenanceMessage.stringValue, 8)
                end
                logInfo("Settings refreshed")
            end
        end
    end)
end

-- ─────────────────────────────────────────────
--  MAIN GUI
-- ─────────────────────────────────────────────
-- Decode a single Firestore REST typed value into a plain Lua value.
local function decodeFirestoreValue(field)
    if type(field) ~= "table" then return nil, false end
    if field.booleanValue ~= nil then
        return field.booleanValue, true
    elseif field.integerValue ~= nil then
        return tonumber(field.integerValue), true
    elseif field.doubleValue ~= nil then
        return tonumber(field.doubleValue), true
    elseif field.stringValue ~= nil then
        return field.stringValue, true
    end
    -- mapValue / arrayValue / nullValue are not used by any flag.
    return nil, false
end

-- ─────────────────────────────────────────────
--  TWO-WAY SYNC STATE
-- ─────────────────────────────────────────────
-- CloudSyncLocked is the master "who wins" switch, toggled from the
-- Management Console at the top of the Settings page.
--   • false (Cloud Synced)  → dashboard is authoritative; remote flag
--                             values are applied to the in-game UI.
--   • true  (Local Override)→ the in-game UI is authoritative; the script
--                             stops accepting remote values and instead
--                             PUSHES its own flag values up to Firestore so
--                             the dashboard mirrors what you do in-game.
local CloudSyncLocked = false

-- Encode a single Lua value into a Firestore REST typed value.
local function encodeFirestoreValue(value)
    local t = type(value)
    if t == "boolean" then
        return { booleanValue = value }
    elseif t == "number" then
        if math.floor(value) == value then
            return { integerValue = tostring(value) }
        end
        return { doubleValue = value }
    elseif t == "string" then
        return { stringValue = value }
    end
    return nil
end

-- Reads a flag's current plain value out of the library's Flags table.
-- Different element types expose their value under different keys
-- (Value for toggles/sliders/dropdowns/textboxes), so we probe the common
-- ones and fall back to nil for anything we can't serialise (e.g. keybinds).
local function readFlagValue(flagEntry)
    if type(flagEntry) ~= "table" then return nil end
    local v = flagEntry.Value
    if v == nil then v = flagEntry.value end
    return v
end

-- Pushes the current in-game flag values up to userSettings/{username}.
-- Used while CloudSyncLocked is true so the dashboard stays in sync with
-- manual in-game changes. Stamps a fresh lastModified so a later unlock
-- doesn't immediately re-apply stale dashboard state.
local function pushLocalSettings(username, ML)
    if not ML or not ML.Flags then return end

    local fields = {
        lastModified   = { integerValue = tostring(os.time()) },
        CloudSyncLocked = { booleanValue = true },
    }

    local count = 0
    for flag, entry in pairs(ML.Flags) do
        -- Only push flags the dashboard can actually drive back (those that
        -- have a matching SetFlags setter), and only serialisable values.
        if ML.SetFlags and ML.SetFlags[flag] then
            local value = readFlagValue(entry)
            local encoded = encodeFirestoreValue(value)
            if encoded then
                fields[flag] = encoded
                count = count + 1
            end
        end
    end

    queueRequest({
        Url     = FIRESTORE_BASE .. "/userSettings/" .. tostring(username),
        Method  = "PATCH",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = HttpService:JSONEncode({ fields = fields }),
    })
    logInfo("LocalOverride: pushed " .. count .. " flag(s) to dashboard")
end

-- Reads userSettings/{username} every 5s. Behaviour depends on the
-- CloudSyncLocked master toggle (see TWO-WAY SYNC STATE above):
--   • Unlocked → applies remote flag values via ML.SetFlags[flag](value).
--   • Locked   → ignores remote values and pushes local flags upward.
-- A monotonically increasing lastModified (Unix seconds) acts as the
-- revision trigger: we only apply when the remote value is newer than the
-- last value we applied, which also prevents echo loops.
local function startRemoteControlPoll(username, ML)
    local docUrl = FIRESTORE_BASE .. "/userSettings/" .. tostring(username)
    local lastModified = 0

    -- Tracks the lock value last written FROM the dashboard, so we can tell
    -- a genuine remote change apart from the value we echo back when locked.
    local lastRemoteLock = nil

    task.spawn(function()
        while true do
            if not ML or not ML.SetFlags then break end
            if not LocalPlayer or not LocalPlayer:IsDescendantOf(game) then break end

            -- ALWAYS read the document first, in every mode. The lock state
            -- can be changed from the website, so we must keep reading even
            -- while locked — otherwise turning the lock OFF on the dashboard
            -- would never be seen and the script would stay locked forever.
            local ok, res = pcall(function()
                return httpRequest({
                    Url     = docUrl,
                    Method  = "GET",
                    Headers = { ["Content-Type"] = "application/json" },
                })
            end)

            if ok and res and res.StatusCode == 200 then
                local parsedOk, parsed = pcall(HttpService.JSONDecode, HttpService, res.Body)
                local fields = parsedOk and type(parsed) == "table" and parsed.fields or nil

                if fields then
                    local remoteModified = 0
                    if fields.lastModified then
                        remoteModified = tonumber(
                            fields.lastModified.integerValue
                            or fields.lastModified.doubleValue
                            or 0) or 0
                    end

                    -- Reconcile the lock from the dashboard in BOTH
                    -- directions. We only adopt the remote lock when it
                    -- actually changed since we last saw it, so the value we
                    -- echo back while locked doesn't re-lock us, and a manual
                    -- in-game toggle isn't instantly reverted by a stale read.
                    if fields.CloudSyncLocked
                        and fields.CloudSyncLocked.booleanValue ~= nil then
                        local remoteLock = fields.CloudSyncLocked.booleanValue
                        if lastRemoteLock == nil then
                            lastRemoteLock = remoteLock
                        elseif remoteLock ~= lastRemoteLock then
                            lastRemoteLock = remoteLock
                            CloudSyncLocked = remoteLock
                            -- Mirror the dashboard's choice onto the UI toggle.
                            if ML.SetFlags and ML.SetFlags["CloudSyncLocked"] then
                                pcall(ML.SetFlags["CloudSyncLocked"], remoteLock)
                            end
                            logInfo("RemoteControl: CloudSyncLocked set to "
                                .. tostring(remoteLock) .. " from dashboard")
                        end
                    end

                    if CloudSyncLocked then
                        -- Local Override: in-game UI is authoritative. Push
                        -- our current flags up so the dashboard mirrors them.
                        pushLocalSettings(username, ML)
                    elseif remoteModified > lastModified then
                        -- Cloud Synced: apply the dashboard's newer values.
                        local applied = 0
                        for flag, field in pairs(fields) do
                            if flag ~= "lastModified" and flag ~= "revision"
                                and flag ~= "CloudSyncLocked"
                                and ML.SetFlags[flag] then
                                local value, valid = decodeFirestoreValue(field)
                                if valid then
                                    local setOk, setErr = pcall(ML.SetFlags[flag], value)
                                    if setOk then
                                        applied = applied + 1
                                    else
                                        logWarn("RemoteControl: failed to set "
                                            .. flag .. ": " .. tostring(setErr))
                                    end
                                end
                            end
                        end

                        lastModified = remoteModified
                        logInfo("RemoteControl: applied " .. applied
                            .. " flag(s)  rev=" .. tostring(remoteModified))
                    end
                end
            elseif ok and res and res.StatusCode ~= 404 then
                logWarn("RemoteControl: poll HTTP " .. tostring(res.StatusCode))
            end

            task.wait(5)
        end
    end)
end

local function LoadMainScript(username, ML)
    local LoadingTick = os.clock()

    -- Fires a synthetic press of the CURRENT menu keybind (the key that
    -- toggles/hides the GUI, default Right Ctrl). Hooked to the main GUI's
    -- minimize button via Window.OnMinimize below, so pressing minimize
    -- also hides the GUI via whatever key the user has bound.
    local function pressMenuKeybind()
        pcall(function()
            -- The library stores MenuKeybind as a string such as
            -- "Enum.KeyCode.RightControl". Resolve it back to a KeyCode,
            -- falling back to Right Ctrl if it isn't a plain keyboard key.
            local keyCode = Enum.KeyCode.RightControl
            local bound   = ML and ML.MenuKeybind

            if type(bound) == "string" then
                local name = bound:match("Enum%.KeyCode%.(.+)$")
                if name and Enum.KeyCode[name] then
                    keyCode = Enum.KeyCode[name]
                end
            end

            local VIM = game:GetService("VirtualInputManager")
            VIM:SendKeyEvent(true,  keyCode, false, game)
            task.wait()
            VIM:SendKeyEvent(false, keyCode, false, game)
        end)
    end

    -- Uses the SINGLE shared library instance passed in (never reloads),
    -- so there is no second-load collision with the key system.
    ActiveLib = ML
    flushNotifQueue()

    applyBWTheme(ML)

    local Window = ML:Window({
        Name      = "ExecSync",
        Version   = "v1.4.1",
        Logo      = "135215559087473",
        FadeSpeed = 0.25,
    })

    -- Pressing the minimize button also presses the current menu keybind
    -- (default Right Ctrl) to hide the GUI.
    Window.OnMinimize = pressMenuKeybind

    local Watermark = ML:Watermark("ExecSync | Driving Empire", "135215559087473")
    Watermark:SetVisibility(true)

    local KeybindList = ML:KeybindsList()
    KeybindList:SetVisibility(false)

    local Pages = {
        ["Main"]     = Window:Page({ Name = "Main",          Icon = "7733960981",      SubPages = true }),
        ["Misc"]     = Window:Page({ Name = "Miscellaneous", Icon = "136623465713368",  Columns = 2 }),
        ["Players"]  = Window:Page({ Name = "Player List",   Icon = "103174889897193" }),
        ["Settings"] = Window:Page({ Name = "Settings",      Icon = "137300573942266",  SubPages = true }),
    }

    local MainSub = {
        ["AutoFarm"] = Pages["Main"]:SubPage({ Name = "Auto Farm", Icon = "13107902118",      Columns = 2 }),
        ["CarMods"]  = Pages["Main"]:SubPage({ Name = "Car Mods",  Icon = "103174889897193",  Columns = 2 }),
    }

    -- ── Auto Farm ─────────────────────────────
    do
        local Racing   = MainSub["AutoFarm"]:Section({ Name = "Racing",   Side = 1 })
        local Delivery = MainSub["AutoFarm"]:Section({ Name = "Delivery", Side = 1 })
        local Robbery  = MainSub["AutoFarm"]:Section({ Name = "Robbery",  Side = 2 })

        Racing:Toggle({ Name = "Auto Race",           Flag = "AutoRace",     Default = false, Callback = function() end })
        Racing:Toggle({ Name = "Start Solo",          Flag = "StartSolo",    Default = false, Callback = function() end })
        Racing:Slider({ Name = "Race Speed",          Flag = "RaceSpeed",    Min = 1,  Max = 500, Default = 250, Decimals = 1,   Callback = function() end })
        Racing:Slider({ Name = "Minimum Wait Time",   Flag = "MinWaitTime",  Min = 0,  Max = 10,  Default = 0.5, Decimals = 0.1, Suffix = "s", Callback = function() end })
        Racing:Toggle({ Name = "Auto Vary Wait Time", Flag = "AutoVaryWait", Default = false, Callback = function() end })
        Racing:Dropdown({ Name = "Select Race", Flag = "SelectRace",
            Items = { "Circuit Race", "Street Race", "Derby", "Drag Race" },
            Default = "Circuit Race", MaxSize = 150, Callback = function() end })
        Racing:Label("Auto Drive is not great for revenues,\nif you are trying to farm money use auto rob/arrest", "Left")

        local AutoDeliveryToggle
        AutoDeliveryToggle = Delivery:Toggle({
            Name = "Auto Delivery",
            Flag = "AutoDelivery",
            Default = false,
            Callback = function(enabled)
                if enabled then
                    if not startDeliveryAutoFarm() and AutoDeliveryToggle then
                        AutoDeliveryToggle:Set(false)
                    end
                else
                    stopDeliveryAutoFarm()
                end
            end
        })

        Robbery:Label("!! Use auto rob at your own risk, there is a\nchance of being banned !!\nWE ARE AWARE OF THE BUG WITH ATMS, WE\nARE TRYING TO FIND A WORKAROUND", "Left")
        Robbery:Label("Session Time: 0s", "Left")
        Robbery:Toggle({ Name = "Auto Rob",             Flag = "AutoRob",            Default = false, Callback = function() end })
        Robbery:Toggle({ Name = "Include Cargo Crates", Flag = "IncludeCargoCrates", Default = false, Callback = function() end })
        Robbery:Toggle({ Name = "Anti Cop",             Flag = "AntiCop",            Default = false, Callback = function() end })
        Robbery:Toggle({ Name = "Include Bank Heist",   Flag = "IncludeBankHeist",   Default = false, Callback = function() end })
        Robbery:Toggle({ Name = "Auto Deposit",         Flag = "AutoDeposit",        Default = false, Callback = function() end })
        Robbery:Slider({ Name = "Deposit Threshold",    Flag = "DepositThreshold",   Min = 1, Max = 100, Default = 10, Decimals = 1, Callback = function() end })
        Robbery:Slider({ Name = "Pause Bag Threshold",  Flag = "PauseBagThreshold",  Min = 1, Max = 100, Default = 25, Decimals = 1, Callback = function() end })
    end

    -- ── Car Mods ──────────────────────────────
    do
        local Perf  = MainSub["CarMods"]:Section({ Name = "Performance",    Side = 1 })
        local Extra = MainSub["CarMods"]:Section({ Name = "Extra Features", Side = 2 })

        Perf:Toggle({ Name = "Top Speed",    Flag = "TopSpeedEnabled",     Default = false, Callback = function() end })
        Perf:Slider({ Name = "Speed",         Flag = "TopSpeed",            Min = 1,   Max = 600, Default = 300, Decimals = 1,   Callback = function() end })
        Perf:Toggle({ Name = "Nitrous",       Flag = "NitrousEnabled",      Default = false, Callback = function() end })
        Perf:Slider({ Name = "Scale",         Flag = "NitrousScale",        Min = 0.1, Max = 10,  Default = 2,   Decimals = 0.1, Callback = function() end })
        Perf:Toggle({ Name = "Acceleration",  Flag = "AccelerationEnabled", Default = false, Callback = function() end })
        Perf:Slider({ Name = "Scale",         Flag = "AccelerationScale",   Min = 0.1, Max = 10,  Default = 2,   Decimals = 0.1, Callback = function() end })
        Perf:Toggle({ Name = "Traction",      Flag = "TractionEnabled",     Default = false, Callback = function() end })
        Perf:Slider({ Name = "Scale",         Flag = "TractionScale",       Min = 0.1, Max = 10,  Default = 2,   Decimals = 0.1, Callback = function() end })

        Extra:Toggle({ Name = "Horn Boost",          Flag = "HornBoost",          Default = false, Callback = function() end })
        Extra:Slider({ Name = "Horn Boost Intensity", Flag = "HornBoostIntensity", Min = 1, Max = 10, Default = 1, Decimals = 1, Callback = function() end })
        Extra:Toggle({ Name = "Instant Stop",         Flag = "InstantStop",        Default = false, Callback = function() end })
        Extra:Toggle({ Name = "Car Breakable Aura",   Flag = "CarBreakableAura",   Default = false, Callback = function() end })
        Extra:Toggle({ Name = "Infinite Nitro",       Flag = "InfiniteNitro",      Default = false, Callback = function() end })
    end

    -- ── Miscellaneous ─────────────────────────
    do
        local Rewards   = Pages["Misc"]:Section({ Name = "Rewards",      Side = 1 })
        local Trolling  = Pages["Misc"]:Section({ Name = "Trolling",     Side = 1 })
        local Inventory = Pages["Misc"]:Section({ Name = "Inventory",    Side = 1 })
        local Dealer    = Pages["Misc"]:Section({ Name = "Dealership",   Side = 2 })
        local Optim     = Pages["Misc"]:Section({ Name = "Optimization", Side = 2 })
        local Misc      = Pages["Misc"]:Section({ Name = "Misc",         Side = 2 })
        local Telemetry = Pages["Misc"]:Section({ Name = "Live Telemetry", Side = 2 })

        Rewards:Toggle({ Name = "Auto Claim Daily Rewards",    Flag = "AutoDailyRewards",       Default = false, Callback = function() end })
        Rewards:Toggle({ Name = "Auto Double Daily Rewards",   Flag = "AutoDoubleDailyRewards",  Default = false, Callback = function() end })
        Rewards:Toggle({ Name = "Auto Claim AD Rewards",       Flag = "AutoADRewards",           Default = false, Callback = function() end })
        Rewards:Button({ Name = "Redeem All Codes",            Callback = function() end })
        Rewards:Button({ Name = "Free Trophies (Nascar QUIZ)", Callback = function() end })
        Trolling:Toggle({ Name = "Spam Outfits",               Flag = "SpamOutfits",             Default = false, Callback = function() end })
        Inventory:Toggle({ Name = "Auto Open Packs [$$$]",    Flag = "AutoOpenPacks",           Default = false, Callback = function() end })
        Inventory:Slider({ Name = "Gacha Open Amount",         Flag = "GachaOpenAmount",         Min = 1, Max = 100, Default = 1, Decimals = 1, Callback = function() end })
        Dealer:Dropdown({ Name = "Select Vehicle", Flag = "SelectVehicle",
            Items = { "Cars", "Motorcycles", "Trucks", "Sports Cars" }, Default = "Cars", MaxSize = 200, Callback = function() end })
        Dealer:Button({ Name = "Open Dealership", Callback = function() end })
        Optim:Toggle({ Name = "Disable Rendering",             Flag = "DisableRendering",        Default = false, Callback = function() end })
        Misc:Toggle({ Name = "No Telemetry",                   Flag = "NoTelemetry",             Default = false, Callback = function() end })
        Misc:Toggle({ Name = "Always See Bounties [$$$]",      Flag = "AlwaysSeeBounties",       Default = false, Callback = function() end })
        Misc:Toggle({ Name = "Anti AFK",                       Flag = "AntiAFK",                 Default = false, Callback = function() end })

        -- Live Telemetry: pushes money / display name / team / car / time
        -- elapsed to userStats/{username} so the dashboard can monitor the
        -- session. Replaces the old Discord webhook feature.
        Telemetry:Label("Sends live session stats to the dashboard:\nmoney, name, team, car and time elapsed.", "Left")
        Telemetry:Toggle({ Name = "Live Telemetry", Flag = "LiveTelemetry", Default = false, Callback = function(v)
            TelemetryEnabled = v
            if v then
                pushUserStats(username)   -- immediate first push
                notify("ExecSync", "Live telemetry enabled — stats sent to dashboard.", 3)
            else
                notify("ExecSync", "Live telemetry disabled.", 3)
            end
        end })
        Telemetry:Button({ Name = "Send Stats Now", Callback = function()
            if not TelemetryEnabled then
                notify("ExecSync", "Enable Live Telemetry first.", 3)
                return
            end
            pushUserStats(username)
            notify("ExecSync", "Stats pushed to dashboard.", 3)
        end })
    end

    -- ── Player List ───────────────────────────
    Pages["Players"]:Playerlist({ Callback = function(...) end })

    -- ── Settings ──────────────────────────────
    local SettingsSub = {
        ["Config"]  = Pages["Settings"]:SubPage({ Name = "Configuration", Icon = "137300573942266", Columns = 2 }),
        ["Configs"] = Pages["Settings"]:SubPage({ Name = "Configs",       Icon = "96491224522405",  Columns = 2 }),
        ["Theme"]   = Pages["Settings"]:SubPage({ Name = "Theming",       Icon = "103863157706913", Columns = 2 }),
    }

    do
        local Session = SettingsSub["Config"]:Section({ Name = "Session",        Side = 1 })
        local UI      = SettingsSub["Config"]:Section({ Name = "User Interface", Side = 2 })
        local Anim    = SettingsSub["Config"]:Section({ Name = "Animations",     Side = 2 })

        Session:Label("Driving Empire", "Center")
        Session:Label(tostring(username or LocalPlayer.Name), "Center")
        Session:Label("Place ID: " .. tostring(game.PlaceId), "Center")

        -- ── Cloud Sync Lock (master 2-way sync switch) ─────
        -- ON  = Local Override: in-game changes win and are pushed to the
        --       dashboard; the website can no longer overwrite the UI.
        -- OFF = Cloud Synced: the dashboard is authoritative and its
        --       settings are applied to the UI on each poll.
        Session:Label("Cloud Sync", "Center")
        Session:Toggle({
            Name    = "Lock to In-Game (ignore website)",
            Flag    = "CloudSyncLocked",
            Default = false,
            Callback = function(v)
                CloudSyncLocked = v
                if v then
                    notify("ExecSync", "Cloud Sync LOCKED — in-game settings now override the website.", 4)
                    logInfo("CloudSyncLocked = true (Local Override)")
                    -- Immediately publish current state so the dashboard
                    -- reflects the in-game UI without waiting for the poll.
                    pushLocalSettings(username, ML)
                else
                    notify("ExecSync", "Cloud Sync ENABLED — following website settings.", 4)
                    logInfo("CloudSyncLocked = false (Cloud Synced)")
                end
            end
        })

        Session:Button({ Name = "Rejoin", Callback = function()
            game:GetService("TeleportService"):Teleport(game.PlaceId)
        end })
        Session:Button({ Name = "Server Hop", Callback = function()
            local TS = game:GetService("TeleportService")
            local servers = HttpService:JSONDecode(game:HttpGet(
                "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"
            ))
            for _, sv in ipairs(servers.data) do
                if sv.id ~= game.JobId and sv.playing < sv.maxPlayers then
                    TS:TeleportToPlaceInstance(game.PlaceId, sv.id); return
                end
            end
        end })
        Session:Button({ Name = "Eject", Callback = function()
            logInfo("Eject")
            stopDeliveryAutoFarm(true)
            goOffline()
            ML:Unload()
        end })
        Session:Button({ Name = "Log Out", Callback = function()
            logInfo("Log Out — clearing session")
            deleteSessionFile()
            stopDeliveryAutoFarm(true)
            goOffline()
            notify("ExecSync", "Logged out. Re-run the script to sign in again.", 4)
            task.wait(2); ML:Unload()
        end })
        Session:Button({ Name = "Join Discord", Callback = function()
            if setclipboard then setclipboard(DISCORD_INVITE) end
            notify("ExecSync", "Discord link copied!", 3)
        end })
        Session:Button({ Name = "Copy Game URL", Callback = function()
            local url = "https://www.roblox.com/games/" .. tostring(game.PlaceId)
            if setclipboard then setclipboard(url) end
            notify("ExecSync", "Game URL copied: " .. url, 4)
        end })

        UI:Label("Menu Keybind", "Left"):Keybind({
            Name = "MenuKeybind", Flag = "MenuKeybind", Mode = "toggle",
            Default = Enum.KeyCode.RightControl,
            Callback = function() ML.MenuKeybind = ML.Flags["MenuKeybind"].Key end
        })
        UI:Toggle({ Name = "Keybind List", Flag = "KeybindList", Default = false,
            Callback = function(v) KeybindList:SetVisibility(v) end })
        UI:Toggle({ Name = "Watermark", Flag = "Watermark", Default = true,
            Callback = function(v) Watermark:SetVisibility(v) end })

        -- NOTE: ML.Tween is not externally writable in this library version.
        -- Callbacks are intentionally left empty to prevent the
        -- "attempt to index nil with Tween" and "missing method Create" errors.
        Anim:Slider({ Name = "Time",      Flag = "TweenTime",      Min = 0, Max = 5, Default = 0.3, Decimals = 0.01, Callback = function() end })
        Anim:Dropdown({ Name = "Style",   Flag = "TweenStyle",
            Items = { "Linear","Sine","Quad","Cubic","Quart","Quint","Exponential","Circular","Back","Elastic","Bounce" },
            Default = "Cubic", MaxSize = 150, Callback = function() end })
        Anim:Dropdown({ Name = "Direction", Flag = "TweenDirection",
            Items = { "In","Out","InOut" }, Default = "Out", MaxSize = 80, Callback = function() end })
    end

    do
        local Profiles = SettingsSub["Configs"]:Section({ Name = "Profiles", Side = 1 })
        local Autoload = SettingsSub["Configs"]:Section({ Name = "Autoload", Side = 2 })
        local ConfigSelected, ConfigName
        local CfgDropdown = Profiles:Dropdown({ Name = "Configs", Flag = "ConfigsList", Items = {}, Multi = false,
            Callback = function(v) ConfigSelected = v end })
        Profiles:Textbox({ Name = "Config Name", Flag = "ConfigName", Default = "", Placeholder = "Enter Name",
            Callback = function(v) ConfigName = v end })
        Profiles:Button({ Name = "Create", Callback = function()
            if ConfigName and ConfigName ~= "" then
                writefile(ML.Folders.Configs .. "/" .. ConfigName .. ".json", ML:GetConfig())
                ML:RefreshConfigsList(CfgDropdown)
            end
        end })
        Profiles:Button({ Name = "Delete", Callback = function()
            if ConfigSelected then ML:DeleteConfig(ConfigSelected); ML:RefreshConfigsList(CfgDropdown) end
        end })
        Profiles:Button({ Name = "Load", Callback = function()
            if ConfigSelected then ML:LoadConfig(readfile(ML.Folders.Configs .. "/" .. ConfigSelected)) end
        end })
        Profiles:Button({ Name = "Save", Callback = function()
            if ConfigSelected then ML:SaveConfig(ConfigSelected) end
        end })
        Profiles:Button({ Name = "Refresh List", Callback = function()
            ML:RefreshConfigsList(CfgDropdown)
        end })
        ML:RefreshConfigsList(CfgDropdown)
        Autoload:Button({ Name = "Set Selected As Autoload", Callback = function()
            if ConfigSelected then
                writefile(ML.Folders.Directory .. "/AutoLoadConfig (do not modify this).json",
                    readfile(ML.Folders.Configs .. "/" .. ConfigSelected))
            end
        end })
        Autoload:Button({ Name = "Set Current As Autoload", Callback = function()
            writefile(ML.Folders.Directory .. "/AutoLoadConfig (do not modify this).json", ML:GetConfig())
        end })
        Autoload:Button({ Name = "Remove Autoload", Callback = function()
            writefile(ML.Folders.Directory .. "/AutoLoadConfig (do not modify this).json", "")
        end })
    end

    do
        local Theming  = SettingsSub["Theme"]:Section({ Name = "Theming",  Side = 1 })
        local Profiles = SettingsSub["Theme"]:Section({ Name = "Profiles", Side = 2 })
        local Autoload = SettingsSub["Theme"]:Section({ Name = "Autoload", Side = 2 })

        ML.ThemeColorpickers = ML.ThemeColorpickers or {}
        for Index, Value in ML.Theme do
            ML.ThemeColorpickers[Index] = Theming:Label(Index, "Left"):Colorpicker({
                Name = "Colorpicker", Flag = "ColorpickerTheme" .. Index,
                Default = Value, Alpha = 0,
                Callback = function(Color)
                    ML.Theme[Index] = Color
                    ML:ChangeTheme(Index, Color)
                end
            })
        end
        Profiles:Dropdown({ Name = "Built-in Themes",
            Items = { "Default", "Halloween", "Aqua", "One Tap" }, Default = "Default", MaxSize = 150, Multi = false,
            Callback = function(v)
                local ThemeData = ML.Themes[v == "Default" and "Preset" or v]
                if not ThemeData then return end
                for k, col in ThemeData do
                    ML.Theme[k] = col; ML:ChangeTheme(k, col)
                    if ML.ThemeColorpickers and ML.ThemeColorpickers[k] then
                        ML.ThemeColorpickers[k]:Set(col)
                    end
                end
            end
        })
        local ThemeSelected, ThemeName
        local ThemeDropdown = Profiles:Dropdown({ Name = "Custom Themes", Flag = "ThemesList", Items = {}, Multi = false,
            Callback = function(v) ThemeSelected = v end })
        Profiles:Textbox({ Name = "Theme Name", Flag = "ThemeName", Default = "", Placeholder = "Enter Name",
            Callback = function(v) ThemeName = v end })
        Profiles:Button({ Name = "Save", Callback = function()
            if ThemeName and ThemeName ~= "" then
                writefile(ML.Folders.Themes .. "/" .. ThemeName .. ".json", ML:GetTheme())
                ML:RefreshThemesList(ThemeDropdown)
            end
        end })
        Profiles:Button({ Name = "Load", Callback = function()
            if ThemeSelected then ML:LoadTheme(readfile(ML.Folders.Themes .. "/" .. ThemeSelected)) end
        end })
        ML:RefreshThemesList(ThemeDropdown)
        Autoload:Button({ Name = "Set Selected As Autoload", Callback = function()
            if ThemeSelected then
                writefile(ML.Folders.Directory .. "/AutoLoadTheme (do not modify this).json",
                    readfile(ML.Folders.Themes .. "/" .. ThemeSelected))
            end
        end })
    end

    ML:Init()
    -- Re-apply B&W after Init, since Init loads any saved autoload theme
    -- which would otherwise override the black & white palette.
    applyBWTheme(ML)
    goOnline(username)
    ML:Notification({
        Name        = "ExecSync",
        Description = "Loaded in: " .. string.format("%.4f", os.clock() - LoadingTick)
            .. "s  •  " .. tostring(username)
            .. "  •  Place: " .. tostring(game.PlaceId),
        Duration    = 5,
        Icon        = "116339777575852",
        IconColor   = Color3.fromRGB(255, 255, 255),
    })

    startSettingsPoll(ML)
    startRemoteControlPoll(username, ML)
    SessionStart = os.time()
    startStatsLoop(username)
    logInfo("Main GUI loaded for " .. tostring(username))
end

-- ─────────────────────────────────────────────
--  KEY SYSTEM
-- ─────────────────────────────────────────────
local function BuildKeySystem(onSuccess, KW)
    -- Uses the SINGLE shared library instance passed in.
    ActiveLib = KW
    applyBWTheme(KW)

    -- Compact, single-window, chrome-stripped login window.
    local Win = KW:Window({
        Name      = "ExecSync",
        Version   = "key",
        Logo      = "135215559087473",
        Size      = UDim2.new(0, 270, 0, 200),
        FadeSpeed = 0.2,
    })

    local Page = Win:Page({
        Name    = "Key",
        Columns = 1,
    })

    local Section = Page:Section({
        Name = "Authentication",
        Side = 1,
    })

    local enteredCode  = ""
    local enteredToken = ""
    local isVerifying  = false

    local function finish(token)
        saveToken(token)
        logInfo("Session saved for " .. LocalPlayer.Name)
        notify("ExecSync", "Verified! Loading ExecSync…", 3)
        task.wait(1)

        -- Post-verification handoff.
        --   1. Fully build and load the main GUI (it is visible immediately
        --      after ML:Init() inside LoadMainScript).
        --   2. Fully unload ONLY the verification window.
        --
        -- The previous version minimized then unminimized the main window to
        -- hide the swap, but Window:Minimize()/UnMinimize() route through the
        -- library's Tween path, which throws "attempt to index nil with
        -- 'Tween'" in this library revision and tore the GUI down right after
        -- it loaded. We no longer call those; building then unloading the key
        -- window is enough and never hits the broken path.
        if onSuccess then
            -- Builds the entire main GUI; returns once it is fully loaded.
            onSuccess(KW.AdoptedUser or LocalPlayer.Name)
        end

        -- Give the main GUI a moment to finish its fade-in before we remove
        -- the key window, so there is never a frame with no visible UI.
        task.wait(0.3)

        -- Remove ONLY the verification window's own frame.
        --
        -- CRITICAL: the key window and the main GUI are built on the SAME
        -- shared library instance (SharedLib is passed as both KW and ML).
        -- Calling Win:Unload() / Library:Unload() tears down the entire
        -- shared library Holder, which destroys the main GUI we just built
        -- as well, making both UIs vanish. So we must NOT unload the shared
        -- instance. Destroying just this window's MainFrame removes the key
        -- UI while leaving the shared library and the main GUI intact.
        pcall(function()
            if Win.Items and Win.Items["MainFrame"] then
                Win.Items["MainFrame"].Instance:Destroy()
            end
        end)

        isVerifying = false
    end

    -- ===== Code =====
    Section:Textbox({
        Name        = "Enter code",
        Flag        = "KeyInput",
        Default     = "",
        Placeholder = "5-digit code",
        Callback    = function(v) enteredCode = v end
    })

    Section:Button({
        Name = "Verify code",
        Callback = function()
            if isVerifying then
                notify("ExecSync", "Already verifying, please wait…", 2)
                return
            end

            local code = (enteredCode or ""):match("^%s*(.-)%s*$")
            if not code or not code:match("^%d%d%d%d%d$") then
                notify("ExecSync – Key System", "Code must be exactly 5 digits.", 3)
                return
            end

            isVerifying = true
            notify("ExecSync – Key System", "Verifying code…", 4)
            logInfo("Verify code pressed by " .. LocalPlayer.Name)

            task.spawn(function()
                local docName, queryErr = queryByCode(LocalPlayer.Name, code)
                if not docName then
                    notify("ExecSync – Key System", "❌ " .. (queryErr or "Invalid code."), 5)
                    logError("Key rejected: " .. tostring(queryErr))
                    isVerifying = false
                    return
                end

                local token = generateToken()
                local patched, patchErr = writeTokenToDoc(docName, token)
                if not patched then
                    notify("ExecSync – Key System", "❌ " .. (patchErr or "Could not save session."), 5)
                    logError("Token write failed: " .. tostring(patchErr))
                    isVerifying = false
                    return
                end

                finish(token)
            end)
        end
    })

    -- ===== Token (manual resume) =====
    Section:Textbox({
        Name        = "Enter token",
        Flag        = "TokenInput",
        Default     = "",
        Placeholder = "session token",
        Callback    = function(v) enteredToken = v end
    })

    Section:Button({
        Name = "Verify token",
        Callback = function()
            if isVerifying then
                notify("ExecSync", "Already verifying, please wait…", 2)
                return
            end

            local token = (enteredToken or ""):match("^%s*(.-)%s*$")
            if not token or token == "" then
                notify("ExecSync – Key System", "Please paste your token.", 3)
                return
            end

            isVerifying = true
            notify("ExecSync – Key System", "Verifying token…", 4)
            logInfo("Verify token pressed by " .. LocalPlayer.Name)

            task.spawn(function()
                local resolvedUser = queryByToken(token)
                if not resolvedUser then
                    notify("ExecSync – Key System", "❌ Token not recognized.", 5)
                    logWarn("Manual token rejected")
                    isVerifying = false
                    return
                end

                KW.AdoptedUser = resolvedUser
                finish(token)
            end)
        end
    })

    Section:Label("New user: enter your 5-digit code.", "Center")
    Section:Label("Returning: paste your session token.", "Center")

    -- ===== Strip chrome + disable resizing =====
    pcall(function()
        local WindowItems = Win.Items
        local PageItems   = Page.Items

        if WindowItems and WindowItems["Pages"] then
            WindowItems["Pages"].Instance.Visible = false
        end
        if WindowItems and WindowItems["Search"] then
            WindowItems["Search"].Instance.Visible = false
        end
        if WindowItems and WindowItems["MinimizeButton"] then
            WindowItems["MinimizeButton"].Instance.Visible = false
        end
        if WindowItems and WindowItems["UnMinimizeButton"] then
            WindowItems["UnMinimizeButton"].Instance.Visible = false
        end
        if PageItems and PageItems["Inactive"] then
            PageItems["Inactive"].Instance.Visible = false
        end

        if WindowItems and WindowItems["MainFrame"] then
            local MainFrame = WindowItems["MainFrame"].Instance
            for _, Child in ipairs(MainFrame:GetChildren()) do
                if Child:IsA("ImageButton")
                    and Child.Size == UDim2.new(0, 9, 0, 9) then
                    Child.Visible = false
                    Child.Active = false
                    Child.AutoButtonColor = false
                end
            end
        end

        if PageItems and PageItems["Columns"] then
            PageItems["Columns"].Instance.Position = UDim2.new(0, 7, 0, 8)
            PageItems["Columns"].Instance.Size     = UDim2.new(1, -14, 1, -16)
        end
    end)

    -- ===== Auto-fit window height to content =====
    pcall(function()
        local RunService = game:GetService("RunService")
        local MainFrame = Win.Items and Win.Items["MainFrame"]
            and Win.Items["MainFrame"].Instance
        local SectionFrame = Section.Items and Section.Items["Section"]
            and Section.Items["Section"].Instance

        if MainFrame and SectionFrame then
            local TOPBAR, TOP_PAD, BOTTOM_PAD = 35, 8, 8
            local function Fit()
                local ContentHeight = SectionFrame.AbsoluteSize.Y
                if ContentHeight <= 0 then return end
                MainFrame.Size = UDim2.new(0, MainFrame.Size.X.Offset, 0,
                    TOPBAR + TOP_PAD + ContentHeight + BOTTOM_PAD)
            end
            Fit()
            local Elapsed, Conn = 0
            Conn = RunService.RenderStepped:Connect(function(dt)
                Elapsed = Elapsed + dt
                Fit()
                if Elapsed >= 1 then Conn:Disconnect() end
            end)
        end
    end)

    KW:Init()
    logInfo("Key system displayed for " .. LocalPlayer.Name)
end

-- ─────────────────────────────────────────────
--  ENTRY POINT
-- ─────────────────────────────────────────────
logInfo("ExecSync starting — place=" .. tostring(game.PlaceId) .. "  user=" .. LocalPlayer.Name)

task.spawn(function()
    -- Load the UI library ONCE for the whole session. Both the key system
    -- and the main GUI build on this single instance, so there is no
    -- double-load collision (Esp:Create / nil Tween).
    local SharedLib = loadstring(game:HttpGet(LIBRARY_URL))()

    local savedToken = readToken()
    if savedToken and savedToken ~= "" then
        logInfo("Found saved token — validating silently…")
        local resolvedUser = queryByToken(savedToken)
        if resolvedUser then
            logInfo("Session valid → loading for " .. resolvedUser)
            LoadMainScript(resolvedUser, SharedLib)
            return
        else
            logWarn("Saved token invalid — showing key system")
            deleteSessionFile()
        end
    end

    BuildKeySystem(function(username)
        LoadMainScript(username, SharedLib)
    end, SharedLib)
end)
