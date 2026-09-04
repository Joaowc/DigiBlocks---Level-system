local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local PhysicsService    = game:GetService("PhysicsService")

-- CONFIGURAÇÃO DOS GRUPOS DE COLISÃO
local OK, _ = pcall(function()
	-- Registra os grupos se eles não existirem
	PhysicsService:RegisterCollisionGroup("ExpDrops")
	PhysicsService:RegisterCollisionGroup("Player")

	-- Configura as regras de colisão: colide com cenário, ignora jogadores
	PhysicsService:CollisionGroupSetCollidable("ExpDrops", "Default", true)
	PhysicsService:CollisionGroupSetCollidable("ExpDrops", "Player", false)
	PhysicsService:CollisionGroupSetCollidable("ExpDrops", "ExpDrops", true) -- Orbes quicam entre si
end)

local EXP_CONFIG = {
	Exp1 = 10,
	Exp2 = 50,
	Exp3 = 1000000000,
}

local PARTICLE_COLOR = {
	Exp1 = Color3.fromRGB(80,  180, 255),
	Exp2 = Color3.fromRGB(80,  255, 120),
	Exp3 = Color3.fromRGB(255, 210,  40),
}

local BASE_XP      = 100
local XP_SCALE     = 1.5
local MAX_LEVEL    = 500
local RESPAWN_TIME = 4

local ORB_LIFETIME   = 15
local BLINK_START    = 12 
local DROP_COUNT     = { min = 8, max = 15 }
local SPREAD_RADIUS = 15

local MOB_DROP_TABLE = {
	{ key = "Exp1", weight = 60 },
	{ key = "Exp2", weight = 30 },
	{ key = "Exp3", weight = 10 },
}
local MOB_DROP_TOTAL = 0
for _, e in ipairs(MOB_DROP_TABLE) do MOB_DROP_TOTAL += e.weight end

local function rollMobDrop()
	local roll = math.random(1, MOB_DROP_TOTAL)
	local acc  = 0
	for _, e in ipairs(MOB_DROP_TABLE) do
		acc += e.weight
		if roll <= acc then return e.key end
	end
	return MOB_DROP_TABLE[1].key
end

local function getXPRequired(level)
	return math.floor(BASE_XP * (level ^ XP_SCALE))
end

local function makeRemote(name)
	if not ReplicatedStorage:FindFirstChild("Remotes") then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local r = ReplicatedStorage.Remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name   = name
		r.Parent = ReplicatedStorage.Remotes
	end
	return r
end

local UpdateHUDEvent = makeRemote("UpdateHUD")
local addLevelRemote = makeRemote("AddLevel") -- adm only
local DamageMultRemote = makeRemote("DamageMultRE") -- adm only

local CombatTable = require(game:GetService("ServerStorage"):WaitForChild("Modules"):WaitForChild("CombatDataTable"))

local function getData(player)
	local pData = CombatTable:GetDatas(player)
	if not pData then return nil end

	if pData.XPToNext < 0 then
		CombatTable:SetData(player, "XPToNext", getXPRequired(pData.Level))
	end
	return pData
end

local function syncHUD(player)
	local d = getData(player)
	if d then
		UpdateHUDEvent:FireClient(player, d.Level, d.XP, d.XPToNext)
	end
end

local function applyLevelAttributes(player, character)
	if not player or not character then return end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	local d = getData(player)
	if d then
		local gain = (d.Level - 1) * 10
		local newMaxHealth = hum.MaxHealth + gain
		hum.MaxHealth = newMaxHealth
		hum.Health    += gain
	end
end

addLevelRemote.OnServerEvent:Connect(function(player, amount)
	-- Valida: só aceita -1 ou 1 pra evitar exploits
	if amount ~= 1 and amount ~= -1 then return end

	local d = getData(player)
	if not d then return end

	local newLevel = math.clamp(d.Level + amount, 1, MAX_LEVEL)
	CombatTable:SetData(player, "Level", newLevel)
	CombatTable:SetData(player, "XPToNext", getXPRequired(newLevel))
	CombatTable:SetData(player, "XP", 0)

	if player.Character then
		applyLevelAttributes(player, player.Character)
	end

	syncHUD(player)
end)

DamageMultRemote.OnServerEvent:Connect(function(player, mult)
	if not player.Character then return end
	local hum = player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	
	hum:SetAttribute("DamageMult", mult)
end)

local function giveXP(player, amount)
	if not player or not player.Parent then return end
	local d = getData(player)
	if not d or d.Level >= MAX_LEVEL then return end

	local currentXP = d.XP + amount
	local leveledUp = false

	while currentXP >= d.XPToNext and d.Level < MAX_LEVEL do
		currentXP  -= d.XPToNext
		d.Level    += 1
		d.XPToNext = getXPRequired(d.Level)
		leveledUp  = true
	end

	CombatTable:SetData(player, "XP", currentXP)
	CombatTable:SetData(player, "Level", d.Level)
	CombatTable:SetData(player, "XPToNext", d.XPToNext)

	if leveledUp and player.Character then
		applyLevelAttributes(player, player.Character)
	end

	syncHUD(player)
end

local function getPlayerFromHit(hit)
	local char = hit.Parent
	if not char then return nil end
	if char:FindFirstChildOfClass("Humanoid") then
		return Players:GetPlayerFromCharacter(char)
	end
	local charParent = char.Parent
	if charParent and charParent:FindFirstChildOfClass("Humanoid") then
		return Players:GetPlayerFromCharacter(charParent)
	end
	return nil
end

local function playDeathBurst(position, expKey)
	local color = PARTICLE_COLOR[expKey]
	local anchor = Instance.new("Part")
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.new(1, 1, 1)
	anchor.CFrame       = CFrame.new(position)
	anchor.Parent       = Workspace

	local att  = Instance.new("Attachment", anchor)
	local emit = Instance.new("ParticleEmitter", att)
	emit.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   color),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1,   color),
	})
	emit.LightEmission  = 1
	emit.LightInfluence = 0
	emit.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.5),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1,   0),
	})
	emit.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1,   1),
	})
	emit.Speed       = NumberRange.new(8, 22)
	emit.SpreadAngle = Vector2.new(180, 180)
	emit.Lifetime    = NumberRange.new(0.5, 1.2)
	emit.Rate        = 0
	emit.RotSpeed    = NumberRange.new(-200, 200)
	emit.Rotation    = NumberRange.new(0, 360)
	emit:Emit(70)

	Debris:AddItem(anchor, 2)
end

local expsFolder = ReplicatedStorage:WaitForChild("Exps", 15)
local expTemplates = {}
for expKey in pairs(EXP_CONFIG) do
	local template = expsFolder and expsFolder:WaitForChild(expKey, 10)
	if template then expTemplates[expKey] = template end
end

-- Garante que todas as partes do jogador pertençam ao grupo "Players"
local function setupCharacterCollision(character)
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CollisionGroup = "Player"
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then 
			d.CollisionGroup = "Player" 
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		setupCharacterCollision(character)
		local hum = character:WaitForChild("Humanoid", 5)
		task.wait(0.5)
		applyLevelAttributes(player, character)
		syncHUD(player)
	end)
end)

local function spawnDropModel(expKey, spawnPosition, launchVelocity, forbiddenCharacters)
	local template = expTemplates[expKey]
	if not template then return end

	local drop  = template:Clone()
	drop.Name   = "Drop_" .. expKey
	drop.Parent = Workspace

	local primaryPart = drop:IsA("BasePart") and drop or drop.PrimaryPart
	local allParts = {}
	local originalVisuals = {}

	if drop:IsA("BasePart") then
		table.insert(allParts, drop)
		originalVisuals[drop] = {Size = drop.Size, Transparency = drop.Transparency}
	end
	for _, d in ipairs(drop:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Massless = true
			table.insert(allParts, d)
			originalVisuals[d] = {Size = d.Size, Transparency = d.Transparency}
		end
	end

	if #allParts == 0 then
		drop:Destroy()
		return
	end

	for _, part in ipairs(allParts) do
		part.Anchored = false
		part.CanCollide = true
		part.CollisionGroup = "ExpDrops" -- Define o grupo de colisão correto para o drop
	end

	if drop:IsA("Model") then
		drop:PivotTo(CFrame.new(spawnPosition))
		if not drop.PrimaryPart then drop.PrimaryPart = allParts[1] end
		drop.PrimaryPart.AssemblyLinearVelocity = launchVelocity
	else
		primaryPart.CFrame = CFrame.new(spawnPosition)
		primaryPart.AssemblyLinearVelocity = launchVelocity
	end

	local collected = false
	local blinkConn

	local function collectDrop(player)
		if collected then return end
		collected = true

		if blinkConn then blinkConn:Disconnect() end

		for _, part in ipairs(allParts) do
			if part and part.Parent then
				part.Anchored = true
				part.CanCollide = false
				if originalVisuals[part] then
					part.Transparency = originalVisuals[part].Transparency
				end
			end
		end

		local currentPos = (drop:IsA("Model") and drop:GetPivot().Position) or primaryPart.Position
		playDeathBurst(currentPos, expKey)

		for part, visuals in pairs(originalVisuals) do
			if part and part.Parent then
				local targetSize = visuals.Size * 1.8
				TweenService:Create(part, 
					TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
					{Size = targetSize, Transparency = 1}
				):Play()
			end
		end

		giveXP(player, EXP_CONFIG[expKey])
		Debris:AddItem(drop, 0.35)
	end

	local function checkTouch(hit)
		if collected then return end
		if hit:IsDescendantOf(drop) then return end
		if forbiddenCharacters then
			for _, forbidden in ipairs(forbiddenCharacters) do
				if hit:IsDescendantOf(forbidden) then return end
			end
		end
		local player = getPlayerFromHit(hit)
		if not player then return end
		local char = player.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end
		collectDrop(player)
	end

	for _, part in ipairs(allParts) do
		part.Touched:Connect(checkTouch)
	end

	task.delay(BLINK_START, function()
		if collected or not drop or not drop.Parent then return end

		local blinkT = 0
		blinkConn = RunService.Heartbeat:Connect(function(dt)
			if collected or not drop or not drop.Parent then
				if blinkConn then blinkConn:Disconnect() end
				return
			end
			blinkT += dt
			local isVisible = (math.floor(blinkT * 12) % 2 == 0)

			for part, visuals in pairs(originalVisuals) do
				if part and part.Parent then
					part.Transparency = isVisible and visuals.Transparency or 0.8
				end
			end
		end)
	end)

	task.delay(ORB_LIFETIME, function()
		if not collected and drop and drop.Parent then 
			if blinkConn then blinkConn:Disconnect() end
			drop:Destroy() 
		end
	end)
end

local function spawnExpDrops(mobPosition, mobCharacter)
	local count = math.random(DROP_COUNT.min, DROP_COUNT.max)

	local forbidden = {}
	if mobCharacter then table.insert(forbidden, mobCharacter) end

	playDeathBurst(mobPosition + Vector3.new(0, 3, 0), "Exp1")

	for i = 1, count do
		task.delay((i - 1) * 0.02, function()
			local dropKey = rollMobDrop()

			local forceX = math.random(-SPREAD_RADIUS, SPREAD_RADIUS) * 1.5
			local forceY = math.random(35, 60) 
			local forceZ = math.random(-SPREAD_RADIUS, SPREAD_RADIUS) * 1.5
			local launchVel = Vector3.new(forceX, forceY, forceZ)

			spawnDropModel(dropKey, mobPosition + Vector3.new(0, 3, 0), launchVel, forbidden)
		end)
	end
end

local function setupMob(humanoid)
	if humanoid:GetAttribute("LevelSystemConnected") then return end
	humanoid:SetAttribute("LevelSystemConnected", true)

	local mobChar: Model = humanoid.Parent
	local mobRoot = mobChar and mobChar:FindFirstChild("HumanoidRootPart")

	humanoid.Died:Connect(function()
		-- Só dropa XP se for morte real
		task.wait(0.3)
		if mobChar:IsDescendantOf(workspace.NPCs) then
			if not mobChar:GetAttribute("RealDeath") then return end
		end

		local dropPosition = Vector3.new(0, 0, 0)

		if mobRoot and mobRoot.Parent then
			dropPosition = mobRoot.Position
		elseif mobChar and mobChar.PrimaryPart then
			dropPosition = mobChar.PrimaryPart.Position
		end

		if dropPosition == Vector3.new(0, 0, 0) then return end
		spawnExpDrops(dropPosition, mobChar)
	end)
end

local function handleNewTaggedMob(instance)
	if instance:IsA("Humanoid") then
		setupMob(instance)
	elseif instance:IsA("Model") then
		local hum = instance:FindFirstChildOfClass("Humanoid")
		if hum then 
			setupMob(hum) 
		else
			local conn
			conn = instance.ChildAdded:Connect(function(child)
				if child:IsA("Humanoid") then
					setupMob(child)
					conn:Disconnect()
				end
			end)
		end
	end
end

CollectionService:GetInstanceAddedSignal("mob"):Connect(handleNewTaggedMob)
for _, instance in ipairs(CollectionService:GetTagged("mob")) do
	handleNewTaggedMob(instance)
end