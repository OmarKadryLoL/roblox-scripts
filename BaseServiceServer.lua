local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local DataService = require(ReplicatedStorage.Packages.DataService).server
local ReplicaServer = require(ReplicatedStorage.Packages.Replica.ReplicaServer)
local NotificationService = require(ReplicatedStorage.Shared.Services.NotificationService)
local IndexService = require(ServerScriptService.Services.IndexService.IndexServiceServer)
local BaseServer = require(ServerScriptService.Classes.BaseServer)
local ServicePlayerData = require(ReplicatedStorage.Packages.ServicePlayerData)
local NewUFO = require(ServerScriptService.Modules.NewUFO)
local UFOs = require(ReplicatedStorage.Shared.Modules.Game.UFOs)
local Rebirths = require(ReplicatedStorage.Shared.Modules.Game.Rebirths)
local Worth = require(ReplicatedStorage.Shared.Modules.Math.Worth)
local CalcOfflineEarnings = require(ReplicatedStorage.Shared.Modules.Math.CalcOfflineEarnings)
local CalcEarningsPerSecond = require(ReplicatedStorage.Shared.Modules.Math.CalcEarningsPerSecond)
local DataTemplate = require(ReplicatedStorage.Shared.Modules.Game.DataTemplate)
local NumberFormatter = require(ReplicatedStorage.Packages.NumberFormatter)
local BaseTypes = require(ReplicatedStorage.Shared.Services.BaseService.BaseTypes)

-- Remotes
local Remotes = ReplicatedStorage.Remotes
local LockBase = Remotes.LockBase
local CollectPodium = Remotes.CollectPodium
local StealUFO = Remotes.StealUFO
local SellUFO = Remotes.SellUFO

-- Assets
local Assets = ReplicatedStorage.Assets
local Animations = Assets.Animations

-- Type Definitions
type BaseTemplate = BaseTypes.BaseTemplate
type BaseServer = BaseServer.BaseServer
type UFO = UFOs.UFO

type CarryingData = {
	ufoUID: string,
	mutation: string,
	victim: Player,
	victimIndex: number,
	pendingIndex: number,
	model: Model,
}

local BaseServiceServer = {
	bases = {} :: { [Player]: BaseServer },
	carrying = {} :: { [Player]: CarryingData },
}

local PLAYER_DATA_TEMPLATE = {
	base = nil,
}

type PlayerData = {
	base: BaseServer,
}

local BASE_SERVICE_TOKEN = ReplicaServer.Token("BaseService")

-- This function initialize BaseServiceServer
function BaseServiceServer.init(self: BaseServiceServer)
	self.replica = ReplicaServer.New({
		Token = BASE_SERVICE_TOKEN,
		Data = {
			bases = {},
			ufos = {} -- { [PodiumIndex] = ufoInstance },	
		},
	})
	self.replica:Replicate()
	self.playerData = ServicePlayerData.new(PLAYER_DATA_TEMPLATE :: PlayerData, self)
	self.baseTemplates = {}
	
	-- This loop gets all the base models are tagged in the game using CollectionService
	for _, baseModel in CollectionService:GetTagged("Base") do
		local index = baseModel:GetAttribute("Index") :: number -- Get the index of base model
		self.baseTemplates[index] = { index = index, baseModel = baseModel, owner = nil } -- set the base template with index, model and owner
	end

	-- thread that process all income for all players
	task.spawn(function()
		while true do
			self:processAllIncome()
			task.wait(1)
		end
	end)
	
	-- This event called when player request to lock base
	LockBase.OnServerEvent:Connect(function(player: Player)
		self:lockBase(player)
	end)
	
	-- This event called when player request to collect podium
	CollectPodium.OnServerEvent:Connect(function(player: Player, podiumIndex: number)
		self:collectPodium(player, podiumIndex)
	end)
	
	-- This event called when player request to steal ufo from another player
	StealUFO.OnServerEvent:Connect(function(theif: Player, victim: Player, podiumIndex: number)
		self:startSteal(theif, victim, podiumIndex)
	end)
	
	-- This event called when player request to sell ufo
	SellUFO.OnServerEvent:Connect(function(player: Player, podiumIndex: number)
		self:sellUFO(player, podiumIndex)
	end)
end

-- This function claim a base for player
function BaseServiceServer.claimBase(self: BaseServiceServer, player: Player): BaseTemplate?
	while player.Parent do -- Check if player is still in game
		-- loop through all baseTemplates
		for i, baseTemplate in self.baseTemplates do
			-- check if the baseTemplate has an owner
			if baseTemplate.owner then
				-- if baseTemplate owner is the same as player then return why return to leave the loop because it means the player already has a base
				if baseTemplate.owner == player then
					return
				end
				continue -- else then continue to next BaseTemplate
			end
			
			baseTemplate.owner = player -- set the owner of the base
			return baseTemplate -- return the base template
		end
		task.wait(1) -- wait 1s to not broke the server
	end
	
	return
end

-- This function called when player join the game
function BaseServiceServer.playerAdded(self: BaseServiceServer, player: Player, playerData: PlayerData)
	local startingChar = player.Character or player.CharacterAdded:Wait()
	self:characterAdded(startingChar) -- init startingChar
	
	-- This event called when player character added
	player.CharacterAdded:Connect(function(character: Model)
		self:characterAdded(character)
	end)
	
	-- Claim base for player
	local baseTemplate = self:claimBase(player)
	if not baseTemplate then
		return -- return if nil
	end
	
	-- Wait for data to load
	DataService:waitForData(player)
	local base = BaseServer.new(baseTemplate, player)
	playerData.base = base
	self.bases[player] = base
	
	self.replica:TableInsert({"bases"}, base)
	
	local podiums = DataService:get(player, { "podiums" })
	for podiumIndex, podium in podiums do
		if podium.unlocked and podium.ufoUID then
			base:placeUFO(podium.ufoUID, podium.mutation, podiumIndex)
		end
	end
	
	for _, ufoInstance in base.placedUFOs do
		self.replica:TableInsert({"ufos"}, ufoInstance)
	end
	
	base.shieldModel.ShieldPart.Touched:Connect(function(otherPart: BasePart)
		local player = Players:GetPlayerFromCharacter(otherPart.Parent)
		if player then
			self:onBaseEntered(player, base.player)
		end
	end)
	
	self:lockBase(player)
	self:offlineEarnMetals(player)
	
	local rebirths = DataService:get(player, { "rebirths" })
	local multAmount = Rebirths.GetMultiplierByRebirths(rebirths)
	local earningsPerSecond = CalcEarningsPerSecond(podiums, rebirths)
	
	base:updateMultUI(multAmount)
	base:updateEarningsPerSecondUI(earningsPerSecond)
	
	DataService:getChangedSignal(player, { "rebirths" }):Connect(function(newRebirths: number)
		local cMultAmount = Rebirths.GetMultiplierByRebirths(newRebirths)
		base:updateMultUI(cMultAmount)
	end)
	
	DataService:getChangedSignal(player, { "podiums" }):Connect(function(newPodiums: {DataTemplate.PodiumSlot})
		local cRebirths = DataService:get(player, { "rebirths" })
		local cEarningsPerSecond = CalcEarningsPerSecond(newPodiums, cRebirths)
		base:updateEarningsPerSecondUI(cEarningsPerSecond)
	end)
end

function BaseServiceServer.playerRemoving(self: BaseServiceServer, player: Player, playerData: PlayerData)	
	local base = playerData.base
	if not base then
		return
	end
	
	local index = base.index
	local baseTemplate = self.baseTemplates[index]
	if baseTemplate.owner == player then
		baseTemplate.owner = nil
	end
	
	self:cancelSteal(player)

	for _, carryingInfo in self.carrying do
		if carryingInfo.victim == player then
			self:removeUFO(player, carryingInfo.victimIndex)
		end
	end
	
	local ufoIndicesToRemove = {}
	for _, ufoInstance in base.placedUFOs do
		local i = table.find(self.replica.Data.ufos, ufoInstance)
		if i then
			table.insert(ufoIndicesToRemove, i)
		end
	end

	table.sort(ufoIndicesToRemove, function(a, b) 
		return a > b 
	end)

	for _, i in ufoIndicesToRemove do
		self.replica:TableRemove({ "ufos" }, i)
	end

	local baseIndex = table.find(self.replica.Data.bases, base)
	if baseIndex then
		self.replica:TableRemove({ "bases" }, baseIndex)
	end

	base:destroy()
	
	DataService:set(player, { "lastLogout" }, os.time())
end

-- This function called when player character added
function BaseServiceServer.characterAdded(self: BaseServiceServer, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Died:Connect(function() -- if player died then cancel the steal
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			self:cancelSteal(player)
		end
	end)
end

-- This function process all income for all players
-- Every second this function will be called to process the income
function BaseServiceServer.processAllIncome(self: BaseServiceServer)
	for player, base in self.bases do
		if not player or not player:IsDescendantOf(Players) then
			continue
		end
		
		local success, profile = pcall(function()
			return DataService:getProfile(player)
		end)
		
		if not success or not profile then
			continue
		end
		
		local rebirths = DataService:get(player, "rebirths")
		local podiums = DataService:get(player, "podiums")
		
		for podiumIndex, podiumData in podiums do
			if podiumData.unlocked and podiumData.ufoUID then
				local ufoData = UFOs.GetUFODataByUID(podiumData.ufoUID)
				if not ufoData then continue end
				
				local income = Worth(ufoData.incomePerSecond, podiumData.mutation, rebirths)
				podiumData.storedMetals += income
				base:updatePodiumGenerating(podiumIndex, podiumData.storedMetals)
			end
		end
		
		DataService:set(player, "podiums", podiums)
	end
end

-- this function checks if the player has placed a UFO on any podium
-- It return true if the player has placed a ufo on any podium else return false
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

-- Checks if the podium is in pending state
-- like if the player is carrying a ufo
-- This function to ignore any errors and prevent player from placing a ufo on podium that already in use or pending
function BaseServiceServer.isPodiumIndexPending(self: BaseServiceServer, player: Player, podiumIndex: number): boolean
	local base = self.bases[player]
	if not base then
		return true
	end
	return base:isPodiumIndexPending(podiumIndex)
end

-- here a function to check if the player can place a ufo
-- like if there's an available podium that is unlocked and not pending and not in use
function BaseServiceServer.canPlaceUFO(self: BaseServiceServer, player: Player): (boolean, number)
	local data = DataService:waitForData(player)
	local podiums = data:get("podiums")
	
	for podiumIndex, podiumData in podiums do
		if self:isPodiumIndexPending(player, podiumIndex) then
			continue
		end
		
		if podiumData.unlocked and not podiumData.ufoUID then
			return true, podiumIndex
		end
	end
	
	return false, -1
end

-- this function to lock the base
-- it will lock the base and if its already locked so it will send notify to the player
-- it will handle the lock time and everything about locking
function BaseServiceServer.lockBase(self: BaseServiceServer, player: Player)
	local data = DataService:waitForData(player)
	
	local base = self.bases[player]
	if not base then return end
	
	-- this check if the base is alredy locked
	if base.isShielded then
		NotificationService:sendNotification(player, {
			text = "Your base is already locked!",
			type = "error",
			sound = "Error",
		}) -- send error notification
		return
	end
	
	base:lockBase() -- lock the base
	
	local rebirths = data:get("rebirths")
	local lockTimer = Rebirths.GetLockedTimeByRebirths(rebirths)
	
	NotificationService:sendNotification(player, {
		text = `You locked your base for {NumberFormatter:formatDuration(lockTimer)}!`,
		type = "success",
		sound = "BaseLock",
	}) -- send success notification
	
	local startTime = os.time()
	local endTime = startTime + lockTimer
	
	task.spawn(function()
		while base.isShielded and os.time() < endTime do
			local timeLeft = endTime - os.time()
			base:updateLockTime(timeLeft)
			task.wait(1)
		end
	end)
	
	task.delay(lockTimer, function()
		base:unlockBase()
	end)
end

-- this function is simply force unlock base
-- it will force unlock the base
function BaseServiceServer.unlockBase(self: BaseServiceServer, player: Player)
	local base = self.bases[player]
	if base then
		base:unlockBase()
	end
end

-- This functino is called when player request to sell ufo
-- it will check the podium if thers a ufo if yes so it will sell and give the player half price of the ufo
function BaseServiceServer.sellUFO(self: BaseServiceServer, player: Player, podiumIndex: number)
	local data = DataService:waitForData(player)
	
	local podium = data:get({"podiums", podiumIndex} :: { string | number })
	if podium and podium.unlocked and podium.ufoUID then
		local ufoData = UFOs.GetUFODataByUID(podium.ufoUID)
		if not ufoData then return end
		
		local worth = math.floor(ufoData.price / 2)
		DataService:update(player, "metals", function(metals: number)
			return metals + worth
		end)
		
		-- force remove ufo 
		self:removeUFO(player, podiumIndex)
	end
end

-- This function called when player request to collect the stored metals from podium
-- check if the podium has stored metals and then if there's stored metals so it will reset the storedMetals to zero and give the amount to the player
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
		
		-- this to reset the billboard
		local base = self.bases[player]
		if base then
			base:updatePodiumGenerating(podiumIndex, 0)
		end
	end
end

-- this a private function check if player CAN AFFORD UFO and return bool val
-- if false so it will return false and left amount to send notification
-- if true so it will return true and price so I can remove the amount from the player
local function canAffordUFO(player: Player, ufo: UFO): (boolean, number)
	local data = DataService:waitForData(player)
	
	local price = ufo.price
	if data:get("metals") < price then
		return false, ufo.price - data:get("metals")
	end
	
	return true, price
end

-- private function to send error nofiication that is base is full
local function notifyNoAvailablePodium(player: Player)
	NotificationService:sendNotification(player, {
		text = "Your base is full!",
		type = "error",
		sound = "Error",
	})
end

-- This function called when player request to steal a ufo from another player
-- check if theif is not carrying something
-- check if theif can place ufo like there's an empty podium
-- get theif base
-- play the carry animation and mark the podium as pending until the stealing process is finished
-- send notification to victim that someone is stealing their UFO
function BaseServiceServer.startSteal(self: BaseServiceServer, thief: Player, victim: Player, victimPodiumIndex: number)
	local victimData = DataService:waitForData(victim)
	local podium = victimData:get({"podiums", victimPodiumIndex} :: { string | number })
	
	if not podium or not podium.ufoUID then return end
	if self.carrying[thief] then return end -- Already carrying something!
	
	local canPlace, podiumIndex = self:canPlaceUFO(thief)
	if not canPlace then
		notifyNoAvailablePodium(thief)
		return
	end
	
	local thiefBase = self.bases[thief]
	if not thiefBase then return end
	
	local character = thief.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local upperTorso = character and character:FindFirstChild("UpperTorso") :: BasePart
	if not character or not humanoid or not upperTorso then return end
	
	-- this is like cloning the same ufo model
	local ufoInstance = NewUFO.newUFOCarried(podium.ufoUID, podium.mutation)
	local ufoModel = ufoInstance.instance
	
	ufoModel.Parent = character
	ufoModel:PivotTo(upperTorso.CFrame * CFrame.new(0, 5, 0))
	
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = ufoModel.PrimaryPart
	weld.Part1 = upperTorso
	weld.Parent = ufoModel
	
	local victimBase = self.bases[victim]
	local originalModel = if victimBase then victimBase.placedUFOs[victimPodiumIndex] else nil
	
	if originalModel then
		originalModel.instance.Parent = nil 
	end
	
	humanoid.WalkSpeed = 23
	
	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator	
	local animationTrack = animator:LoadAnimation(Animations.Carry) :: AnimationTrack
	animationTrack:Play()
	
	self.carrying[thief] = {
		ufoUID = podium.ufoUID,
		mutation = podium.mutation or "Normal",
		victim = victim,
		victimIndex = victimPodiumIndex,
		pendingIndex = podiumIndex,
		model = ufoModel,
	}	
	if thief.Character then
		thief.Character:SetAttribute("Carrying", true)
	end
	thiefBase:markPodiumIndexPending(podiumIndex)
	
	local ufoData = UFOs.GetUFODataByUID(podium.ufoUID)
	if ufoData then
		NotificationService:sendNotification(victim, {
			text = `Someone is stealing your {ufoData.displayName}`,
			type = "error",
			sound = "Error"
		})
	end
end

-- This function called when the stealing process to force cancel
-- clear pending podium
-- if the victim is still in game restore the ufo back to his base
-- destroy the carried ufo model
-- stop carry animation
-- clear carrying data and back player to default speed
function BaseServiceServer.cancelSteal(self: BaseServiceServer, thief: Player)
	local info = self.carrying[thief]
	if not info then return end
	
	local thiefBase = self.bases[thief]
	if thiefBase then
		thiefBase:clearPendingPodiumIndex(info.pendingIndex)
	end
	
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

				local attach = podium:FindFirstChildWhichIsA("Attachment", true)
				if attach then
					originalInstance.instance.Parent = attach
					local billboard = originalInstance.instance:FindFirstChildWhichIsA("BillboardGui")
					if billboard then
						billboard.Parent = nil
						task.delay(0.5, function()
							billboard.Parent = originalInstance.instance
						end)
					end
				end
				
				self.replica:TableInsert({"ufos"}, originalInstance)
			end
		end
	end
	
	if info.model then
		info.model:Destroy()
	end
	
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
	
	self.carrying[thief] = nil
	if thief.Character then
		thief.Character:SetAttribute("Carrying", nil)
	end
end

-- This function called when player enter his own base while carrying a stolen ufo
-- place the stolen ufo to pending podium
-- remove the ufo from victim base
-- destroy the carried ufo model and stop carry animation
-- clear carrying data and set player default speed
-- send notifications to both players
function BaseServiceServer.onBaseEntered(self: BaseServiceServer, player: Player, enteredBaseOwner: Player)
	local info = self.carrying[player]
	if not info then return end
	
	if player ~= enteredBaseOwner then
		return
	end
	
	self:insertUFO(player, info.ufoUID, info.mutation, info.pendingIndex)
	
	if info.victim and info.victim:IsDescendantOf(Players) then
		self:removeUFO(info.victim, info.victimIndex)
	end

	if info.model then
		info.model:Destroy()
	end

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

	self.carrying[player] = nil
	if player.Character then
		player.Character:SetAttribute("Carrying", nil)
	end

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

	DataService:update(player, "steals", function(steals: number)
		return steals + 1
	end)
end

-- This function called when player request to buy a ufo
-- check if player has an available podium
-- check if player can afford the ufo
-- remove the price from player metals
-- send purchase notification and return the podium index
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
	
	DataService:update(player, "metals", function(metals: number)
		return metals - amount
	end)
	
	NotificationService:sendNotification(player, {
		text = `You purchased {ufo.displayName}!`,
		type = "success",
	})
	
	return true, podiumIndex
end

-- This function called when player request to buy a ufo
-- check if player has an empty podium
-- check if player can afford the ufo
-- remove the price from player metals
-- send purchase notification and return the podium index
function BaseServiceServer.insertUFO(self: BaseServiceServer, player: Player, ufoUID: string, mutation: string, podiumIndex: number)	
	local base = self.bases[player]
	if not base then return end
	
	local isPodiumIndexPending = self:isPodiumIndexPending(player, podiumIndex)
	if isPodiumIndexPending then
		base:clearPendingPodiumIndex(podiumIndex)
	end
	
	local podiumData = DataService:get(player, { "podiums", podiumIndex } :: { string | number })
	podiumData.ufoUID = ufoUID
	podiumData.mutation = mutation
	
	DataService:set(player, { "podiums", podiumIndex } :: { string | number }, podiumData)
	
	IndexService:discoverIndex(player, ufoUID)
	base:placeUFO(ufoUID, mutation, podiumIndex)
	
	self.replica:TableInsert({"ufos"}, base.placedUFOs[podiumIndex])	
end

-- This function remove a ufo from player base
-- clear the ufo data and reset stored metals
-- remove the replicated ufo
-- remove the ufo model from the base
-- clear pending podium and reset podium ui
function BaseServiceServer.removeUFO(self: BaseServiceServer, player: Player, podiumIndex: number)	
	local data = DataService:waitForData(player)
	
	local podium = data:get({"podiums", podiumIndex} :: { string | number })
	if podium and podium.unlocked and podium.ufoUID then
		podium.storedMetals = 0
		podium.ufoUID = nil
		
		DataService:set(player, {"podiums", podiumIndex} :: { string | number }, podium)
	end
	
	local base = self.bases[player]
	if base then
		local index = table.find(self.replica.Data.ufos, base.placedUFOs[podiumIndex])
		if index then
			self.replica:TableRemove({"ufos"}, index)
		end
		
		base:removeUFO(podiumIndex)
		base:clearPendingPodiumIndex(podiumIndex)
		base:updatePodiumGenerating(podiumIndex, 0)
	end
end

-- This function calculate the metals earned while player was offline
-- get the offline time using the last logout time
-- calculate earned metals for every placed ufo
-- add the earned metals to each podium
function BaseServiceServer.offlineEarnMetals(self: BaseServiceServer, player: Player)
	local data = DataService:waitForData(player)
	
	local lastLogout = data:get("lastLogout")
	if not lastLogout then return end
	
	local offlineTime = os.time() - lastLogout
	if offlineTime <= 0 then return end
	
	local rebirths = data:get("rebirths")
	local podiums = data:get("podiums")
	
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

type BaseServiceServer = typeof(BaseServiceServer) & {
	replica: ReplicaServer.Replica,
	playerData: ServicePlayerData.ServicePlayerData<PlayerData>,
	baseTemplates: { [number]: BaseTemplate },
}

return BaseServiceServer :: BaseServiceServer
