--[[
    BaseServiceServer
    
    This is the main server-side service that manages everything related to player bases.
    It handles: claiming bases, placing/removing/stealing UFOs, processing income every second,
    collecting podium earnings, locking bases with a shield, and offline earnings when a player
    comes back after being away.
    
    This service follows a pattern where each player gets their own BaseServer object,
    and all base-related remote events from the client are routed through here.
--]]

-- Services: Roblox built-in services used throughout this script
local CollectionService = game:GetService("CollectionService") -- Used to find all Base models tagged in the game
local ReplicatedStorage = game:GetService("ReplicatedStorage")  -- Shared folder accessible by both server and client
local ServerScriptService = game:GetService("ServerScriptService") -- Server-only scripts and modules
local Players = game:GetService("Players") -- Tracks all connected players

-- External modules: custom systems required for data, replication, notifications, etc.
local DataService = require(ReplicatedStorage.Packages.DataService).server -- Handles persistent player data (metals, podiums, rebirths, etc.)
local ReplicaServer = require(ReplicatedStorage.Packages.Replica.ReplicaServer) -- Replicates server state to all clients in real time
local NotificationService = require(ReplicatedStorage.Shared.Services.NotificationService) -- Sends UI notifications to players
local IndexService = require(ServerScriptService.Services.IndexService.IndexServiceServer) -- Tracks which UFOs a player has discovered
local BaseServer = require(ServerScriptService.Classes.BaseServer) -- The class that represents one player's physical base in the world
local ServicePlayerData = require(ReplicatedStorage.Packages.ServicePlayerData) -- Per-player data scoped to this service
local NewUFO = require(ServerScriptService.Modules.NewUFO) -- Factory module for creating UFO model instances
local UFOs = require(ReplicatedStorage.Shared.Modules.Game.UFOs) -- UFO definitions: UIDs, income rates, prices, display names
local Rebirths = require(ReplicatedStorage.Shared.Modules.Game.Rebirths) -- Rebirth multiplier and lock timer calculations
local Worth = require(ReplicatedStorage.Shared.Modules.Math.Worth) -- Calculates real income value after mutation and rebirth multipliers
local CalcOfflineEarnings = require(ReplicatedStorage.Shared.Modules.Math.CalcOfflineEarnings) -- Calculates metals earned while player was offline
local CalcEarningsPerSecond = require(ReplicatedStorage.Shared.Modules.Math.CalcEarningsPerSecond) -- Total EPS across all active podiums
local DataTemplate = require(ReplicatedStorage.Shared.Modules.Game.DataTemplate) -- Type definitions for data structures
local NumberFormatter = require(ReplicatedStorage.Packages.NumberFormatter) -- Formats numbers and durations for UI display
local BaseTypes = require(ReplicatedStorage.Shared.Services.BaseService.BaseTypes) -- Shared type definitions for bases

-- Remote Events: fired from the client to trigger server actions
local Remotes = ReplicatedStorage.Remotes
local LockBase = Remotes.LockBase         -- Client requests to lock/shield their base
local CollectPodium = Remotes.CollectPodium -- Client requests to collect stored metals from a podium
local StealUFO = Remotes.StealUFO         -- Client initiates a UFO steal from another player's base
local SellUFO = Remotes.SellUFO           -- Client sells a UFO from one of their podiums

-- Asset folder references
local Assets = ReplicatedStorage.Assets
local Animations = Assets.Animations -- Animation tracks (e.g., the "Carry" animation played while stealing)

-- Type aliases for cleaner function signatures
type BaseTemplate = BaseTypes.BaseTemplate
type BaseServer = BaseServer.BaseServer
type UFO = UFOs.UFO

--[[
    CarryingData: describes the state of a player currently carrying a stolen UFO.
    This is stored per-thief while the steal is in progress, and cleared once
    the thief reaches their own base or the steal is cancelled.
--]]
type CarryingData = {
	ufoUID: string,      -- Which UFO is being carried
	mutation: string,    -- The mutation variant of that UFO
	victim: Player,      -- The player being stolen from
	victimIndex: number, -- Which podium slot the UFO came from on the victim's base
	pendingIndex: number,-- Which podium slot on the thief's base is reserved for this UFO
	model: Model,        -- The carried UFO model welded to the thief's character
}

--[[
    BaseServiceServer: the main table that acts as a singleton service.
    All methods and state live here. It is initialized by the game's service loader.
--]]
local BaseServiceServer = {
	bases = {} :: { [Player]: BaseServer },       -- Maps each player to their active BaseServer instance
	carrying = {} :: { [Player]: CarryingData },  -- Tracks players currently mid-steal
}

-- Per-player data template for this service: just a reference to the player's BaseServer object
local PLAYER_DATA_TEMPLATE = {
	base = nil,
}

type PlayerData = {
	base: BaseServer,
}

-- A unique token used to identify this service's Replica on the client side
local BASE_SERVICE_TOKEN = ReplicaServer.Token("BaseService")

--[[
    init: called once when the server starts.
    Sets up the Replica for client replication, binds all remote events,
    and starts the income processing loop.
--]]
function BaseServiceServer.init(self: BaseServiceServer)	
	-- Create a shared Replica that replicates the list of bases and placed UFOs to all clients
	self.replica = ReplicaServer.New({
		Token = BASE_SERVICE_TOKEN,
		Data = {
			bases = {},
			ufos = {}, -- List of active UFO instances visible on bases (used by clients for rendering/UI)
		},
	})
	self.replica:Replicate() -- Immediately start replicating to all current and future clients

	-- Initialize per-player data tracking for this service
	self.playerData = ServicePlayerData.new(PLAYER_DATA_TEMPLATE :: PlayerData, self)

	-- Build a lookup table of all Base models in the world, keyed by their Index attribute
	self.baseTemplates = {}
	for _, baseModel in CollectionService:GetTagged("Base") do
		local index = baseModel:GetAttribute("Index") :: number
		self.baseTemplates[index] = { index = index, baseModel = baseModel, owner = nil }
	end

	-- Background loop: every second, process income for all active bases
	task.spawn(function()
		while true do
			self:processAllIncome()
			task.wait(1)
		end
	end)

	-- Connect remote events to their handler methods
	LockBase.OnServerEvent:Connect(function(player: Player)
		self:lockBase(player)
	end)

	CollectPodium.OnServerEvent:Connect(function(player: Player, podiumIndex: number)
		self:collectPodium(player, podiumIndex)
	end)

	StealUFO.OnServerEvent:Connect(function(theif: Player, victim: Player, podiumIndex: number)
		self:startSteal(theif, victim, podiumIndex)
	end)

	SellUFO.OnServerEvent:Connect(function(player: Player, podiumIndex: number)
		self:sellUFO(player, podiumIndex)
	end)
end

--[[
    claimBase: finds an unclaimed base template and assigns it to the player.
    Loops and retries every second if all bases are currently taken.
    Returns the claimed BaseTemplate, or nil if the player left before claiming.
--]]
function BaseServiceServer.claimBase(self: BaseServiceServer, player: Player): BaseTemplate?
	while player.Parent do -- player.Parent is nil once they leave the game
		for i, baseTemplate in self.baseTemplates do
			if baseTemplate.owner then
				-- Skip bases that are already claimed; also stop if this player already owns one
				if baseTemplate.owner == player then
					return
				end
				continue
			end

			-- Claim this base for the player and return it immediately
			baseTemplate.owner = player
			return baseTemplate
		end
		task.wait(1) -- All bases are taken; wait and try again
	end

	return -- Player left while waiting; nothing to claim
end

--[[
    initBase: called when a player joins. Claims a base for them, loads their
    saved podium data (UFOs + stored metals), connects income/rebirth UI updates,
    runs the offline earnings calculation, and locks the base to start.
--]]
function BaseServiceServer.initBase(self: BaseServiceServer, player: Player, playerData: PlayerData)
	local baseTemplate = self:claimBase(player)
	if not baseTemplate then
		return -- Player left before a base was available
	end

	DataService:waitForData(player) -- Wait until the player's save data is loaded from the datastore

	-- Create the BaseServer instance which manages the physical base in the world
	local base = BaseServer.new(baseTemplate, player)
	playerData.base = base
	self.bases[player] = base

	-- Add this base to the replicated list so clients can see it
	self.replica:TableInsert({"bases"}, base)

	-- Restore any UFOs the player had placed in their last session
	local podiums = DataService:get(player, { "podiums" })
	for podiumIndex, podium in podiums do
		if podium.unlocked and podium.ufoUID then
			base:placeUFO(podium.ufoUID, podium.mutation, podiumIndex)
		end
	end

	-- Also replicate the restored UFO instances to clients
	for _, ufoInstance in base.placedUFOs do
		self.replica:TableInsert({"ufos"}, ufoInstance)
	end

	-- When another player touches the shield boundary, check if a steal should resolve
	base.shieldModel.ShieldPart.Touched:Connect(function(otherPart: BasePart)
		local player = Players:GetPlayerFromCharacter(otherPart.Parent)
		if player then
			self:onBaseEntered(player, base.player)
		end
	end)

	-- Lock the base immediately on join and apply offline earnings
	self:lockBase(player)
	self:offlineEarnMetals(player)

	-- Set initial UI values for the rebirth multiplier and earnings-per-second display
	local rebirths = DataService:get(player, { "rebirths" })
	local multAmount = Rebirths.GetMultiplierByRebirths(rebirths)
	local earningsPerSecond = CalcEarningsPerSecond(podiums, rebirths)
	base:updateMultUI(multAmount)
	base:updateEarningsPerSecondUI(earningsPerSecond)

	-- Keep the multiplier UI in sync whenever the player rebirths
	DataService:getChangedSignal(player, { "rebirths" }):Connect(function(newRebirths: number)
		local cMultAmount = Rebirths.GetMultiplierByRebirths(newRebirths)
		base:updateMultUI(cMultAmount)
	end)

	-- Keep the EPS UI in sync whenever the player's podium state changes (UFO placed or removed)
	DataService:getChangedSignal(player, { "podiums" }):Connect(function(newPodiums: {DataTemplate.PodiumSlot})
		local cRebirths = DataService:get(player, { "rebirths" })
		local cEarningsPerSecond = CalcEarningsPerSecond(newPodiums, cRebirths)
		base:updateEarningsPerSecondUI(cEarningsPerSecond)
	end)
end

--[[
    processAllIncome: runs every second for every active base.
    For each unlocked podium with a UFO, calculates income (adjusted for mutation
    and rebirths), adds it to storedMetals, and updates the podium display.
    Uses pcall to safely skip players whose data isn't ready yet.
--]]
function BaseServiceServer.processAllIncome(self: BaseServiceServer)
	for player, base in self.bases do
		-- Skip players who have already left the game
		if not player or not player:IsDescendantOf(Players) then
			continue
		end

		-- Safely attempt to access the player profile; skip if not ready
		local success, profile = pcall(function()
			return DataService:getProfile(player)
		end)
		if not success or not profile then
			continue
		end

		local rebirths = DataService:get(player, "rebirths")
		local podiums = DataService:get(player, "podiums")

		-- Iterate each podium and credit income if a UFO is actively placed there
		for podiumIndex, podiumData in podiums do
			if podiumData.unlocked and podiumData.ufoUID then
				local ufoData = UFOs.GetUFODataByUID(podiumData.ufoUID)
				if not ufoData then continue end

				-- Worth() applies mutation bonus and rebirth multiplier to the base income rate
				local income = Worth(ufoData.incomePerSecond, podiumData.mutation, rebirths)
				podiumData.storedMetals += income
				base:updatePodiumGenerating(podiumIndex, podiumData.storedMetals)
			end
		end

		-- Save the updated storedMetals values back to the datastore
		DataService:set(player, "podiums", podiums)
	end
end

--[[
    hasPlacedUFO: checks whether a specific UFO (by ID) is already on the player's base.
    Used to prevent duplicate placements.
--]]
function BaseServiceServer.hasPlacedUFO(self: BaseServiceServer, player: Player, ufoId: string): boolean
	local ufoData = UFOs.UFOs[ufoId]
	if not ufoData then
		return false
	end

	local data = DataService:waitForData(player)
	local podiums = data:get("podiums")

	for _, podiumData in podiums do
		if podiumData.unlocked and podiumData.ufoUID == ufoData.uid then
			return true
		end
	end

	return false
end

--[[
    isPodiumIndexPending: returns true if a podium slot is currently reserved
    (e.g. a steal is in progress targeting that slot). Prevents double-booking.
--]]
function BaseServiceServer.isPodiumIndexPending(self: BaseServiceServer, player: Player, podiumIndex: number): boolean
	local base = self.bases[player]
	if not base then
		return true -- Treat as pending if base doesn't exist yet (safe default)
	end
	return base:isPodiumIndexPending(podiumIndex)
end

--[[
    canPlaceUFO: finds the first available (unlocked, empty, non-pending) podium slot.
    Returns (true, podiumIndex) if a slot is free, or (false, -1) if the base is full.
--]]
function BaseServiceServer.canPlaceUFO(self: BaseServiceServer, player: Player): (boolean, number)
	local data = DataService:waitForData(player)
	local podiums = data:get("podiums")

	for podiumIndex, podiumData in podiums do
		if self:isPodiumIndexPending(player, podiumIndex) then
			continue -- Skip slots reserved by in-progress operations
		end

		if podiumData.unlocked and not podiumData.ufoUID then
			return true, podiumIndex -- Found a free slot
		end
	end

	return false, -1 -- No free slots available
end

--[[
    lockBase: activates the shield on the player's base for a duration determined
    by their rebirth count. Notifies the player, counts down the timer on the base UI,
    and automatically unlocks when the timer expires.
--]]
function BaseServiceServer.lockBase(self: BaseServiceServer, player: Player)
	local data = DataService:waitForData(player)

	local base = self.bases[player]
	if not base then return end

	-- Prevent locking an already-shielded base
	if base.isShielded then
		NotificationService:sendNotification(player, {
			text = "Your base is already locked!",
			type = "error",
			sound = "Error",
		})
		return
	end

	base:lockBase() -- Activates the shield model and sets isShielded = true

	-- Shield duration scales with rebirth count (higher rebirths = longer protection)
	local rebirths = data:get("rebirths")
	local lockTimer = Rebirths.GetLockedTimeByRebirths(rebirths)

	NotificationService:sendNotification(player, {
		text = `You locked your base for {NumberFormatter:formatDuration(lockTimer)}!`,
		type = "success",
		sound = "BaseLock",
	})

	local startTime = os.time()
	local endTime = startTime + lockTimer

	-- Background coroutine: update the countdown display on the base UI every second
	task.spawn(function()
		while base.isShielded and os.time() < endTime do
			local timeLeft = endTime - os.time()
			base:updateLockTime(timeLeft)
			task.wait(1)
		end
	end)

	-- Automatically remove the shield once the timer runs out
	task.delay(lockTimer, function()
		base:unlockBase()
	end)
end

--[[
    unlockBase: manually removes the shield from a player's base.
    Called internally (e.g. on player remove or after timer).
--]]
function BaseServiceServer.unlockBase(self: BaseServiceServer, player: Player)
	local base = self.bases[player]
	if base then
		base:unlockBase()
	end
end

--[[
    sellUFO: removes a UFO from a podium and refunds the player half of its purchase price.
    This simulates a standard sell mechanic (50% resale value).
--]]
function BaseServiceServer.sellUFO(self: BaseServiceServer, player: Player, podiumIndex: number)
	local data = DataService:waitForData(player)

	local podium = data:get({"podiums", podiumIndex} :: { string | number })
	if podium and podium.unlocked and podium.ufoUID then
		local ufoData = UFOs.GetUFODataByUID(podium.ufoUID)
		if not ufoData then return end

		-- Refund is 50% of the original price, floored to avoid fractional metals
		local worth = math.floor(ufoData.price / 2)
		DataService:update(player, "metals", function(metals: number)
			return metals + worth
		end)

		self:removeUFO(player, podiumIndex) -- Clean up the podium slot and model
	end
end

--[[
    collectPodium: transfers all stored metals from a podium into the player's metal balance.
    Resets the stored amount to 0 and updates the podium display.
--]]
function BaseServiceServer.collectPodium(self: BaseServiceServer, player: Player, podiumIndex: number)
	local data = DataService:waitForData(player)
	local podium = data:get({"podiums", podiumIndex} :: { string | number })
	if podium and podium.unlocked and podium.storedMetals > 0 then
		local worth = podium.storedMetals
		podium.storedMetals = 0

		data:set({"podiums", podiumIndex} :: { string | number }, podium)
		DataService:update(player, "metals", function(metals: number)
			return metals + worth
		end)

		-- Reset the generating display on this podium back to 0
		local base = self.bases[player]
		if base then
			base:updatePodiumGenerating(podiumIndex, 0)
		end
	end
end

-- Local helper: checks if the player can afford a UFO and returns how much is missing if not
local function canAffordUFO(player: Player, ufo: UFO): (boolean, number)
	local data = DataService:waitForData(player)

	local price = ufo.price
	if data:get("metals") < price then
		return false, ufo.price - data:get("metals") -- Return the shortfall amount
	end

	return true, price
end

-- Local helper: sends a "base is full" error notification to the player
local function notifyNoAvailablePodium(player: Player)
	NotificationService:sendNotification(player, {
		text = "Your base is full!",
		type = "error",
		sound = "Error",
	})
end

--[[
    startSteal: initiates the UFO steal sequence.
    
    Validates that:
    - The victim has a UFO on that podium
    - The thief isn't already carrying something
    - The thief has a free podium slot
    - The thief's character is valid
    
    Then spawns a carried UFO model welded to the thief's torso, plays the carry
    animation, hides the original UFO from the victim's base, and marks the
    thief's target podium as pending. The steal completes in onBaseEntered()
    when the thief walks back onto their own base.
--]]
function BaseServiceServer.startSteal(self: BaseServiceServer, thief: Player, victim: Player, victimPodiumIndex: number)
	local victimData = DataService:waitForData(victim)
	local podium = victimData:get({"podiums", victimPodiumIndex} :: { string | number })

	if not podium or not podium.ufoUID then return end -- Nothing to steal
	if self.carrying[thief] then return end -- Thief is already in the middle of another steal

	-- Check whether the thief has room on their base
	local canPlace, podiumIndex = self:canPlaceUFO(thief)
	if not canPlace then
		notifyNoAvailablePodium(thief)
		return
	end

	local thiefBase = self.bases[thief]
	if not thiefBase then return end

	-- Validate the thief's character parts needed for welding and animation
	local character = thief.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local upperTorso = character and character:FindFirstChild("UpperTorso") :: BasePart
	if not character or not humanoid or not upperTorso then return end

	-- Create the carried UFO model and attach it above the thief's torso using a WeldConstraint
	local ufoInstance = NewUFO.newUFOCarried(podium.ufoUID, podium.mutation)
	local ufoModel = ufoInstance.instance
	ufoModel.Parent = character
	ufoModel:PivotTo(upperTorso.CFrame * CFrame.new(0, 5, 0)) -- Position 5 studs above the torso

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = ufoModel.PrimaryPart
	weld.Part1 = upperTorso
	weld.Parent = ufoModel

	-- Hide the original UFO model from the victim's base while it is being carried
	local victimBase = self.bases[victim]
	local originalModel = if victimBase then victimBase.placedUFOs[victimPodiumIndex] else nil
	if originalModel then
		originalModel.instance.Parent = nil
	end

	-- Slow walk speed slightly while carrying (23 vs normal 35)
	humanoid.WalkSpeed = 23

	-- Play the Carry animation on the thief
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator
	local animationTrack = animator:LoadAnimation(Animations.Carry) :: AnimationTrack
	animationTrack:Play()

	-- Store all carry state so it can be resolved or cancelled later
	self.carrying[thief] = {
		ufoUID = podium.ufoUID,
		mutation = podium.mutation or "Normal",
		victim = victim,
		victimIndex = victimPodiumIndex,
		pendingIndex = podiumIndex,
		model = ufoModel,
	}

	-- Set an attribute on the character so the client knows the player is carrying
	if thief.Character then
		thief.Character:SetAttribute("Carrying", true)
	end

	-- Reserve the target podium slot so nothing else claims it
	thiefBase:markPodiumIndexPending(podiumIndex)

	-- Notify the victim that their UFO is being stolen
	local ufoData = UFOs.GetUFODataByUID(podium.ufoUID)
	if ufoData then
		NotificationService:sendNotification(victim, {
			text = `Someone is stealing your {ufoData.displayName}`,
			type = "error",
			sound = "Error"
		})
	end
end

--[[
    cancelSteal: aborts an in-progress steal.
    
    Called when the thief dies, leaves, or the victim disconnects mid-steal.
    Restores the original UFO to the victim's base, destroys the carried model,
    resets the thief's walk speed and animation, and clears all carry state.
--]]
function BaseServiceServer.cancelSteal(self: BaseServiceServer, thief: Player)
	local info = self.carrying[thief]
	if not info then return end

	-- Release the reserved podium slot on the thief's base
	local thiefBase = self.bases[thief]
	if thiefBase then
		thiefBase:clearPendingPodiumIndex(info.pendingIndex)
	end

	-- Restore the original UFO to the victim's base if they are still in the game
	if info.victim and info.victim:IsDescendantOf(Players) then
		local victimBase = self.bases[info.victim]
		if victimBase then
			local originalInstance = victimBase.placedUFOs[info.victimIndex]
			if originalInstance then
				local podium = victimBase.podiums[info.victimIndex]
				if not podium then
					self.carrying[thief] = nil
					return
				end

				-- Re-parent the UFO back to its podium attachment point
				local attach = podium:FindFirstChildWhichIsA("Attachment", true)
				if attach then
					originalInstance.instance.Parent = attach

					-- Briefly hide the BillboardGui to avoid a visual glitch on re-parent
					local billboard = originalInstance.instance:FindFirstChildWhichIsA("BillboardGui")
					if billboard then
						billboard.Parent = nil
						task.delay(0.5, function()
							billboard.Parent = originalInstance.instance
						end)
					end
				end

				-- Re-add the UFO to the replicated list so clients see it again
				self.replica:TableInsert({"ufos"}, originalInstance)
			end
		end
	end

	-- Clean up the carried UFO model that was attached to the thief
	if info.model then
		info.model:Destroy()
	end

	-- Restore the thief's normal walk speed and stop the carry animation
	local thiefCharacter = thief.Character
	if thiefCharacter then
		local humanoid = thiefCharacter:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end

		humanoid.WalkSpeed = 35

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				track:Stop()
			end
		end
	end

	-- Clear all carry state for this thief
	self.carrying[thief] = nil
	if thief.Character then
		thief.Character:SetAttribute("Carrying", nil)
	end
end

--[[
    onBaseEntered: fires when a player walks into someone's base shield zone.
    
    If the entering player is the thief AND they have entered their OWN base,
    the steal is resolved: the UFO is inserted into the thief's base, removed
    from the victim's data, and both players receive notifications.
    The steal counter for the thief is also incremented.
--]]
function BaseServiceServer.onBaseEntered(self: BaseServiceServer, player: Player, enteredBaseOwner: Player)
	local info = self.carrying[player]
	if not info then return end -- Player is not carrying anything; nothing to resolve

	-- Only resolve the steal if the player has entered their own base (not the victim's)
	if player ~= enteredBaseOwner then
		return
	end

	-- Complete the steal: place the UFO into the thief's base
	self:insertUFO(player, info.ufoUID, info.mutation, info.pendingIndex)

	-- Remove the UFO from the victim's base data
	if info.victim and info.victim:IsDescendantOf(Players) then
		self:removeUFO(info.victim, info.victimIndex)
	end

	-- Destroy the carried model now that it has been placed
	if info.model then
		info.model:Destroy()
	end

	-- Restore the thief's normal walk speed and stop the carry animation
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end

		humanoid.WalkSpeed = 35

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				track:Stop()
			end
		end
	end

	-- Clear carry state and the Carrying character attribute
	self.carrying[player] = nil
	if player.Character then
		player.Character:SetAttribute("Carrying", nil)
	end

	-- Notify both players about the outcome
	local ufoData = UFOs.GetUFODataByUID(info.ufoUID)
	if ufoData then
		NotificationService:sendNotification(player, {
			text = `You stole {ufoData.displayName}!`,
			type = "success",
			sound = "StealSuccess",
		})
		NotificationService:sendNotification(info.victim, {
			text = `{player.DisplayName} Stole your {ufoData.displayName}`,
			type = "error",
			sound = "Error",
		})
	end

	-- Increment the thief's total steal count in their saved data
	DataService:update(player, "steals", function(steals: number)
		return steals + 1
	end)
end

--[[
    buyUFO: validates that the player can afford and has room for a UFO, then deducts
    the cost. Returns (true, podiumIndex) on success so the caller can proceed with
    placement, or (false, -1) if the purchase failed.
--]]
function BaseServiceServer.buyUFO(self: BaseServiceServer, player: Player, ufo: UFO): (boolean, number)
	local canPlace, podiumIndex = self:canPlaceUFO(player)
	if canPlace == false then
		notifyNoAvailablePodium(player)
		return false, -1
	end

	local canAfford, amount = canAffordUFO(player, ufo)
	if canAfford == false then
		NotificationService:sendNotification(player, {
			text = `You need {NumberFormatter:formatSmartCompact(amount)} more!`,
			type = "error",
			sound = "Error",
		})
		return false, -1
	end

	-- Deduct the cost from the player's metals
	DataService:update(player, "metals", function(metals: number)
		return metals - amount
	end)

	NotificationService:sendNotification(player, {
		text = `You purchased {ufo.displayName}!`,
		type = "success",
	})

	return true, podiumIndex
end

--[[
    insertUFO: places a UFO into a specific podium slot on a player's base.
    Clears any pending reservation on that slot, updates the saved data,
    triggers the IndexService to log the discovery, and replicates the new UFO instance.
--]]
function BaseServiceServer.insertUFO(self: BaseServiceServer, player: Player, ufoUID: string, mutation: string, podiumIndex: number)
	local base = self.bases[player]
	if not base then return end

	-- If the slot was pending (e.g. reserved by a steal), release that reservation first
	local isPodiumIndexPending = self:isPodiumIndexPending(player, podiumIndex)
	if isPodiumIndexPending then
		base:clearPendingPodiumIndex(podiumIndex)
	end

	-- Write the UFO data into the player's saved podium slot
	local podiumData = DataService:get(player, { "podiums", podiumIndex } :: { string | number })
	podiumData.ufoUID = ufoUID
	podiumData.mutation = mutation
	DataService:set(player, { "podiums", podiumIndex } :: { string | number }, podiumData)

	-- Notify the index system that the player has encountered this UFO (for collection tracking)
	IndexService:discoverIndex(player, ufoUID)

	-- Physically spawn the UFO model on the podium
	base:placeUFO(ufoUID, mutation, podiumIndex)

	-- Replicate the new UFO instance to all clients
	self.replica:TableInsert({"ufos"}, base.placedUFOs[podiumIndex])
end

--[[
    removeUFO: removes a UFO from a podium slot.
    Clears the UFO data from the save, removes it from the replica list,
    destroys the physical model, and resets the podium generating display.
--]]
function BaseServiceServer.removeUFO(self: BaseServiceServer, player: Player, podiumIndex: number)
	local data = DataService:waitForData(player)

	local podium = data:get({"podiums", podiumIndex} :: { string | number })
	if podium and podium.unlocked and podium.ufoUID then
		-- Clear the UFO reference and discard any stored metals
		podium.storedMetals = 0
		podium.ufoUID = nil
		DataService:set(player, {"podiums", podiumIndex} :: { string | number }, podium)
	end

	local base = self.bases[player]
	if base then
		-- Remove this UFO instance from the replicated list before destroying it
		local index = table.find(self.replica.Data.ufos, base.placedUFOs[podiumIndex])
		if index then
			self.replica:TableRemove({"ufos"}, index)
		end

		base:removeUFO(podiumIndex)
		base:clearPendingPodiumIndex(podiumIndex)
		base:updatePodiumGenerating(podiumIndex, 0) -- Reset the podium counter to 0
	end
end

--[[
    offlineEarnMetals: calculates and credits metals earned while the player was offline.
    Uses the player's last logout timestamp and the CalcOfflineEarnings formula
    to determine how much each UFO would have generated during the absence.
--]]
function BaseServiceServer.offlineEarnMetals(self: BaseServiceServer, player: Player)
	local data = DataService:waitForData(player)

	local lastLogout = data:get("lastLogout")
	if not lastLogout then return end -- First time playing; no offline time to calculate

	local offlineTime = os.time() - lastLogout
	if offlineTime <= 0 then return end -- Sanity check: time should always be positive

	local rebirths = data:get("rebirths")
	local podiums = data:get("podiums")

	-- For each podium with an active UFO, calculate and add offline earnings to storedMetals
	for podiumIndex, podiumData in podiums do
		if podiumData.unlocked and podiumData.ufoUID then
			local ufoData = UFOs.GetUFODataByUID(podiumData.ufoUID)
			if not ufoData then continue end

			local earnedMetals = CalcOfflineEarnings(offlineTime, ufoData.incomePerSecond, rebirths)
			DataService:update(player, {"podiums", podiumIndex, "storedMetals"}, function(metals: number)
				return metals + earnedMetals
			end)
		end
	end
end

--[[
    characterAdded: called whenever a player's character spawns.
    Connects a Died event so that if the thief dies while carrying a UFO,
    the steal is automatically cancelled and the UFO is returned.
--]]
function BaseServiceServer.characterAdded(self: BaseServiceServer, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			self:cancelSteal(player) -- Cancel any active steal if the thief dies
		end
	end)
end

--[[
    playerAdded: called by the service loader when a player joins.
    Hooks up character events and initialises the player's base.
--]]
function BaseServiceServer.playerAdded(self: BaseServiceServer, player: Player, playerData: PlayerData)
	-- Handle the case where the character already exists when playerAdded fires
	if player.Character then
		self:characterAdded(player.Character)
	end

	-- Also handle all future respawns
	player.CharacterAdded:Connect(function(character: Model)
		self:characterAdded(character)
	end)

	self:initBase(player, playerData) -- Set up the player's base
end

--[[
    playerRemoving: called when a player leaves.
    
    - Frees their base template for another player to claim
    - Cancels any active steal they were doing
    - Removes UFOs from the replica list and destroys the base
    - Records their logout time for offline earnings on next join
--]]
function BaseServiceServer.playerRemoving(self: BaseServiceServer, player: Player, playerData: PlayerData)
	local base = playerData.base
	if not base then
		return
	end

	-- Free the base template slot so another player can claim it
	local index = base.index
	local baseTemplate = self.baseTemplates[index]
	if baseTemplate.owner == player then
		baseTemplate.owner = nil
	end

	self:cancelSteal(player) -- Cancel if this player was stealing from someone

	-- If another player was in the process of stealing from this player, remove the UFO cleanly
	for _, carryingInfo in self.carrying do
		if carryingInfo.victim == player then
			self:removeUFO(player, carryingInfo.victimIndex)
		end
	end

	-- Collect indices of UFO instances to remove from the replica, then sort descending
	-- to safely remove from the array without shifting indices during iteration
	local ufoIndicesToRemove = {}
	for _, ufoInstance in base.placedUFOs do
		local i = table.find(self.replica.Data.ufos, ufoInstance)
		if i then
			table.insert(ufoIndicesToRemove, i)
		end
	end

	table.sort(ufoIndicesToRemove, function(a, b)
		return a > b -- Descending order: remove highest indices first to avoid index shifting
	end)

	for _, i in ufoIndicesToRemove do
		self.replica:TableRemove({ "ufos" }, i)
	end

	-- Remove the base itself from the replicated bases list
	local baseIndex = table.find(self.replica.Data.bases, base)
	if baseIndex then
		self.replica:TableRemove({ "bases" }, baseIndex)
	end

	base:destroy() -- Clean up the physical base in the world

	-- Save the logout time so CalcOfflineEarnings works correctly on next join
	DataService:set(player, { "lastLogout" }, os.time())
end

-- Type declaration for the full service object including fields added during init
type BaseServiceServer = typeof(BaseServiceServer) & {
	replica: ReplicaServer.Replica,
	playerData: ServicePlayerData.ServicePlayerData<PlayerData>,
	baseTemplates: { [number]: BaseTemplate },
}

return BaseServiceServer :: BaseServiceServer
