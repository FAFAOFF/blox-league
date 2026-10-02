-- ===== [ ZEN-BOT v4 : IA STYLE "ZEN" (ROCKET LEAGUE) ] =====
-- Script SERVEUR : à mettre dans ServerScriptService (un Script, PAS un LocalScript).
-- À utiliser avec ZenBotControls.client.lua (LocalScript dans StarterPlayerScripts).
--
-- • Touche K : active / désactive les bots
-- • Touche M : change le mode 1v1 → 2v2 → 3v3
-- • Les bots remplissent automatiquement les places vides en équipe BLEUE et ORANGE
-- • Chaque bot sait dans quelle équipe il est (couleur, but à défendre, but à attaquer)
--
-- Mouvements imités de Zen :
--   kickoff rapide (dash type speed flip), dribbles collés avec crochets,
--   flicks (pop, 45°), air dribbles, aériens / double tap, tirs dans les coins,
--   feintes, 50/50 agressifs avec dash, bumps/démos,
--   rotations rapides, shadow défense, pas de double commit entre coéquipiers.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ===== [ RÉGLAGES PRINCIPAUX ] =====
local SETTINGS = {
	StartEnabled = true,          -- bots actifs au lancement du serveur ?
	Mode = 3,                     -- joueurs par équipe : 1 = 1v1, 2 = 2v2, 3 = 3v3
	Level = "SSL",                -- "SSL" (niveau Zen), "Champion" ou "Platine"

	-- Noms dans ton jeu
	BallName = "Ball",
	BlueGoalName = "GoalBleu",    -- but défendu par l'équipe BLEUE
	OrangeGoalName = "GoalOrange",-- but défendu par l'équipe ORANGE

	-- Qui a le droit d'utiliser les touches K / M (en plus du créateur du jeu)
	Admins = {
		-- 123456789, -- mets ici des UserId
	},

	ThinkRate = 0.05,             -- le bot réfléchit 20 fois par seconde
	RespawnDelay = 3,
	SetupWarnDelay = 10,

	-- Déplacement + boost
	WalkSpeed = 24,
	BoostMultiplier = 1.6,
	BoostDrain = 33,
	BoostRegen = 10,
	BoostMinDistance = 20,
	DashSpeed = 70,
	DashDuration = 0.18,
	DashCooldown = 1.2,

	AimError = 4,                 -- erreur de visée max en degrés (0 = parfait)

	KickRange = 4.5,
	KickCooldown = 0.2,

	DribbleSpeedFactor = 1.08,
	DribbleCutAngle = 40,

	FlickTriggerDistance = 12,
	FlickPower = 55,
	FlickLift = 45,

	AirDribbleLift = 28,
	AirDribbleDuration = 2.5,

	ShootDistance = 70,
	ShotPower = 100,
	ShotLift = 12,
	CornerAim = 0.7,

	AerialMinHeight = 4,
	AerialMaxHeight = 14,
	AerialPower = 85,
	AerialLift = 5,

	ChallengeMargin = 6,
	ChallengePower = 80,

	FakeChance = 0.4,
	FakeDuration = 0.6,

	EnableBumps = true,
	BumpRange = 5,
	BumpPower = 60,
	BumpCooldown = 3,

	DefenseLine = 0.3,
}

-- ===== [ NIVEAUX ] =====
-- Chaque niveau remplace certains réglages ci-dessus
local LEVELS = {
	SSL = { WalkSpeed = 26, AimError = 1.5, KickCooldown = 0.15, DashCooldown = 1.0, FakeChance = 0.5 },
	Champion = { WalkSpeed = 23, AimError = 5, KickCooldown = 0.25, FakeChance = 0.25 },
	Platine = { WalkSpeed = 20, AimError = 10, KickCooldown = 0.35, FakeChance = 0.1, EnableBumps = false },
}
for key, value in pairs(LEVELS[SETTINGS.Level] or {}) do
	SETTINGS[key] = value
end

-- ===== [ ÉQUIPES ] =====
local TEAMS = {
	Blue = {
		Label = "Bleu",
		Color = Color3.fromRGB(0, 110, 255),
		OwnGoal = SETTINGS.BlueGoalName,
		TargetGoal = SETTINGS.OrangeGoalName,
	},
	Orange = {
		Label = "Orange",
		Color = Color3.fromRGB(255, 140, 0),
		OwnGoal = SETTINGS.OrangeGoalName,
		TargetGoal = SETTINGS.BlueGoalName,
	},
}
local TEAM_KEYS = { "Blue", "Orange" }

-- Reconnaît l'équipe d'un joueur (Team nommée "Bleu"/"Blue" ou "Orange")
local function teamOf(player)
	local team = player.Team
	if not team then return nil end
	local name = string.lower(team.Name)
	if string.find(name, "bleu") or string.find(name, "blue") then return "Blue" end
	if string.find(name, "orange") then return "Orange" end
	return nil
end

-- ===== [ UTILITAIRES ] =====
local cache = {}
local function findCached(name)
	local inst = cache[name]
	if inst and inst.Parent then return inst end
	inst = workspace:FindFirstChild(name, true)
	cache[name] = inst
	return inst
end

-- Centre du but, axe de sa largeur et demi-largeur
local function getGoalInfo(inst)
	if not inst then return nil end
	local cf, size
	if inst:IsA("BasePart") then
		cf, size = inst.CFrame, inst.Size
	elseif inst:IsA("Model") then
		cf, size = inst:GetBoundingBox()
	else
		return nil
	end
	if size.X >= size.Z then
		return { center = cf.Position, axis = cf.RightVector, half = size.X / 2 }
	end
	return { center = cf.Position, axis = cf.LookVector, half = size.Z / 2 }
end

-- Direction horizontale (sans Y), sans NaN si le vecteur est nul
local function flat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-3 then return Vector3.zero end
	return f.Unit
end

local function hdist(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function rotateY(dir, degrees)
	return CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(dir)
end

local function nearest(actors, position)
	local best, bestDist = nil, math.huge
	for _, actor in ipairs(actors) do
		local d = (actor.root.Position - position).Magnitude
		if d < bestDist then
			best, bestDist = actor, d
		end
	end
	return best, bestDist
end

-- Pousse une pièce à l'horizontale pendant un court instant (dash, bump)
local function planeImpulse(part, velocity, duration)
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.xAxis
	lv.SecondaryTangentAxis = Vector3.zAxis
	lv.PlaneVelocity = Vector2.new(velocity.X, velocity.Z)
	lv.MaxForce = 1e6
	lv.Parent = part
	Debris:AddItem(lv, duration)
	Debris:AddItem(attachment, duration)
end

-- Vise le coin du but le plus loin du gardien adverse
local function pickShotTarget(goal, opponents)
	local keeper = nearest(opponents, goal.center)
	local left = goal.center - goal.axis * goal.half * SETTINGS.CornerAim
	local right = goal.center + goal.axis * goal.half * SETTINGS.CornerAim
	if not keeper then
		return math.random() < 0.5 and left or right
	end
	if (keeper.root.Position - left).Magnitude > (keeper.root.Position - right).Magnitude then
		return left
	end
	return right
end

-- L'adversaire est-il sur le chemin de la balle vers le but ?
local function isInPath(oppPos, ballPos, toGoal)
	local rel = Vector3.new(oppPos.X - ballPos.X, 0, oppPos.Z - ballPos.Z)
	local along = rel:Dot(toGoal)
	local lateral = (rel - toGoal * along).Magnitude
	return along > 0 and along < 20 and lateral < 6
end

-- ===== [ ÉTAT GLOBAL ] =====
local enabled = SETTINGS.StartEnabled
local mode = math.clamp(SETTINGS.Mode, 1, 3)
local needRebalance = true
local botsByTeam = { Blue = {}, Orange = {} }
local allBots = {}
local lastServerTouch = 0

-- Tous les joueurs et bots vivants sur le terrain
local function getActors()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			table.insert(list, { root = root, team = teamOf(plr) })
		end
	end
	for _, bot in ipairs(allBots) do
		if bot:alive() then
			table.insert(list, { root = bot.root, team = bot.team })
		end
	end
	return list
end

-- ===== [ BOT ] =====
local Bot = {}
Bot.__index = Bot

function Bot.new(teamKey, slot)
	return setmetatable({ team = teamKey, slot = slot, info = TEAMS[teamKey] }, Bot)
end

-- Position de départ : devant son but, décalé selon sa place (1, 2 ou 3)
function Bot:spawnPosition()
	local own = getGoalInfo(findCached(self.info.OwnGoal))
	local target = getGoalInfo(findCached(self.info.TargetGoal))
	if not (own and target) then return Vector3.new(0, 10, 0) end
	local forward = flat(target.center - own.center)
	local side = Vector3.yAxis:Cross(forward)
	return own.center + forward * 20 + side * ((self.slot - 2) * 10) + Vector3.new(0, 3, 0)
end

function Bot:spawn()
	local description = Instance.new("HumanoidDescription")
	local color = self.info.Color
	description.HeadColor = color
	description.TorsoColor = color
	description.LeftArmColor = color
	description.RightArmColor = color
	description.LeftLegColor = color
	description.RightLegColor = color

	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = "Zen " .. self.info.Label .. " " .. self.slot
	model:PivotTo(CFrame.new(self:spawnPosition()))
	model.Parent = workspace

	self.model = model
	self.humanoid = model:WaitForChild("Humanoid")
	self.root = model:WaitForChild("HumanoidRootPart")
	pcall(function() self.root:SetNetworkOwner(nil) end) -- le serveur contrôle le bot
	self.humanoid.WalkSpeed = SETTINGS.WalkSpeed
	self.humanoid.DisplayName = model.Name

	self.boost = 100
	self.boosting = false
	self.lastKick, self.lastDash, self.lastBump = 0, 0, 0
	self.airDribbleUntil, self.fakeUntil, self.nextFakeCheck = 0, 0, 0
	self.stuckTime, self.lastPos, self.moveTarget = 0, nil, nil
	self.diedAt = nil
end

function Bot:despawn()
	if self.model then self.model:Destroy() end
	self.model = nil
end

function Bot:alive()
	return self.model ~= nil and self.model.Parent ~= nil and self.humanoid.Health > 0
end

function Bot:splitActors(actors)
	local opponents, teammates = {}, {}
	for _, actor in ipairs(actors) do
		if actor.root ~= self.root then
			if actor.team == self.team then
				table.insert(teammates, actor)
			else
				table.insert(opponents, actor)
			end
		end
	end
	return opponents, teammates
end

-- Frappe la balle (avec une petite erreur de visée "humaine")
function Bot:hit(ball, direction, power, lift)
	local now = os.clock()
	if now - self.lastKick < SETTINGS.KickCooldown then return false end
	self.lastKick = now

	local dir = rotateY(direction, (math.random() * 2 - 1) * SETTINGS.AimError)
	pcall(function() ball:SetNetworkOwner(nil) end)
	ball.AssemblyLinearVelocity = dir * power + Vector3.new(0, lift, 0)
	lastServerTouch = now
	return true
end

-- Dash (speed flip au kickoff, flip dans les duels)
function Bot:dash(direction)
	local now = os.clock()
	if direction == Vector3.zero or now - self.lastDash < SETTINGS.DashCooldown then return end
	self.lastDash = now
	planeImpulse(self.root, direction * SETTINGS.DashSpeed, SETTINGS.DashDuration)
end

-- Déplacement avec gestion du boost
function Bot:move(target, dt, forceBoost)
	local far = hdist(target, self.root.Position) > SETTINGS.BoostMinDistance
	if (far or forceBoost) and self.boost > 0 then
		self.boost = math.max(0, self.boost - SETTINGS.BoostDrain * dt)
		self.humanoid.WalkSpeed = SETTINGS.WalkSpeed * SETTINGS.BoostMultiplier
		self.boosting = true
	else
		self.boost = math.min(100, self.boost + SETTINGS.BoostRegen * dt)
		self.humanoid.WalkSpeed = SETTINGS.WalkSpeed
		self.boosting = false
	end
	self.moveTarget = target
	self.humanoid:MoveTo(Vector3.new(target.X, self.root.Position.Y, target.Z))
end

-- S'arrête sur place (pour les feintes)
function Bot:hold()
	self.moveTarget = nil
	self.boosting = false
	self.humanoid:MoveTo(self.root.Position)
end

-- Se relève s'il tombe, saute s'il est bloqué
function Bot:unstick(dt)
	local state = self.humanoid:GetState()
	if state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.Ragdoll
		or state == Enum.HumanoidStateType.PlatformStanding then
		self.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end

	local pos = self.root.Position
	if self.lastPos and self.moveTarget
		and hdist(pos, self.lastPos) < 0.05 and hdist(pos, self.moveTarget) > 3 then
		self.stuckTime += dt
		if self.stuckTime > 1 then
			self.humanoid.Jump = true
			self.stuckTime = 0
		end
	else
		self.stuckTime = 0
	end
	self.lastPos = pos
end

-- Flicks : choisit une variante comme Zen
function Bot:flick(ball, toGoal, targetGoal, opponents, goalDist)
	self.humanoid.Jump = true
	local roll = math.random()
	if goalDist < SETTINGS.ShootDistance * 1.6 and roll < 0.4 then
		-- Flick 45° : frappe puissante en diagonale vers le coin
		local aim = flat(pickShotTarget(targetGoal, opponents) - ball.Position)
		self:hit(ball, aim, SETTINGS.ShotPower * 0.9, 25)
	elseif roll < 0.7 then
		-- Pop par-dessus l'adversaire
		self:hit(ball, toGoal, SETTINGS.FlickPower, SETTINGS.FlickLift)
	else
		-- Monte la balle pour lancer un air dribble
		if self:hit(ball, toGoal, 15, 35) then
			self.airDribbleUntil = os.clock() + SETTINGS.AirDribbleDuration
		end
	end
end

-- ===== [ CERVEAU ] =====
function Bot:think(dt, ctx)
	local ownGoal = ctx.goals[self.info.OwnGoal]
	local targetGoal = ctx.goals[self.info.TargetGoal]
	if not (ownGoal and targetGoal) then return end

	local ball = ctx.ball
	local now = os.clock()
	local humanoid, root = self.humanoid, self.root
	local myPos, ballPos = root.Position, ball.Position
	local ballVel = ball.AssemblyLinearVelocity
	local myToBall = (ballPos - myPos).Magnitude
	local flatDist = hdist(ballPos, myPos)
	local ballHeight = ballPos.Y - myPos.Y
	local goalDist = (targetGoal.center - ballPos).Magnitude
	local toGoal = flat(targetGoal.center - ballPos)
	local inAir = humanoid.FloorMaterial == Enum.Material.Air

	local opponents, teammates = self:splitActors(ctx.actors)
	local opp, oppToBall = nearest(opponents, ballPos)
	local oppToMe = opp and (opp.root.Position - myPos).Magnitude or math.huge
	local mate, mateToBall = nearest(teammates, ballPos)

	self:unstick(dt)

	-- BUMP / DÉMO : en plein boost, il percute l'adversaire à sa portée
	if SETTINGS.EnableBumps and opp and self.boosting and oppToMe <= SETTINGS.BumpRange
		and now - self.lastBump > SETTINGS.BumpCooldown then
		self.lastBump = now
		planeImpulse(opp.root, flat(opp.root.Position - myPos) * SETTINGS.BumpPower, 0.15)
	end

	-- 1) KICKOFF : balle immobile au centre → le plus proche de l'équipe y va avec un dash
	if ballVel.Magnitude < 1 and hdist(ballPos, ctx.ballSpawn) < 3 then
		if mate and mateToBall < myToBall then
			self:move(ownGoal.center:Lerp(ballPos, 0.25), dt) -- un coéquipier y va, il couvre
		else
			self:move(ballPos, dt, true)
			if myToBall < 25 and myToBall > 8 then
				self:dash(flat(ballPos - myPos))
			end
			if myToBall <= SETTINGS.KickRange then
				self:hit(ball, toGoal, SETTINGS.ChallengePower, 10)
			end
		end
		return
	end

	-- 2) AIR DRIBBLE EN COURS : petites touches vers le haut jusqu'au but
	if now < self.airDribbleUntil then
		if ballHeight > 0 and flatDist < 8 then
			humanoid.Jump = true
			self:move(ballPos + toGoal * 1.5, dt, true)
			if myToBall <= SETTINGS.KickRange * 1.6 then
				if goalDist <= SETTINGS.ShootDistance * 0.6 then
					-- Fin de l'air dribble : frappe finale dans le coin
					local aim = flat(pickShotTarget(targetGoal, opponents) - ballPos)
					if self:hit(ball, aim, SETTINGS.AerialPower, SETTINGS.AerialLift) then
						self.airDribbleUntil = 0
					end
				else
					self:hit(ball, toGoal, math.max(humanoid.WalkSpeed, 20) * 1.1, SETTINGS.AirDribbleLift)
				end
			end
			return
		end
		self.airDribbleUntil = 0 -- balle perdue ou retombée
	end

	-- 3) AÉRIEN / DOUBLE TAP : balle haute et proche
	if ballHeight > SETTINGS.AerialMinHeight and ballHeight < SETTINGS.AerialMaxHeight and flatDist < 7 then
		humanoid.Jump = true
		self:move(ballPos, dt)
		if inAir and myToBall <= SETTINGS.KickRange * 1.5 then
			if goalDist <= SETTINGS.ShootDistance * 1.3 then
				local aim = flat(pickShotTarget(targetGoal, opponents) - ballPos)
				self:hit(ball, aim, SETTINGS.AerialPower, SETTINGS.AerialLift)
			elseif self:hit(ball, toGoal, 22, SETTINGS.AirDribbleLift) then
				self.airDribbleUntil = now + SETTINGS.AirDribbleDuration
			end
		end
		return
	end

	-- 4) BALLE AU PIED
	if myToBall <= SETTINGS.KickRange then
		if goalDist <= SETTINGS.ShootDistance then
			-- Tir placé dans le coin opposé au gardien
			local aim = flat(pickShotTarget(targetGoal, opponents) - ballPos)
			self:hit(ball, aim, SETTINGS.ShotPower, SETTINGS.ShotLift)
		elseif oppToMe <= SETTINGS.FlickTriggerDistance then
			self:flick(ball, toGoal, targetGoal, opponents, goalDist)
		else
			-- Dribble collé, avec crochet si un adversaire bloque le chemin
			local dir = toGoal
			if opp and isInPath(opp.root.Position, ballPos, toGoal) then
				local away = flat(opp.root.Position - ballPos)
				local a = rotateY(toGoal, SETTINGS.DribbleCutAngle)
				local b = rotateY(toGoal, -SETTINGS.DribbleCutAngle)
				dir = (a:Dot(away) < b:Dot(away)) and a or b
			end
			local speed = math.max(humanoid.WalkSpeed, root.AssemblyLinearVelocity.Magnitude)
			self:hit(ball, dir, speed * SETTINGS.DribbleSpeedFactor, 1)
		end
		self:move(ballPos + toGoal * 2, dt)
		return
	end

	-- 5) PAS DE DOUBLE COMMIT : un coéquipier est nettement plus proche → soutien
	if mate and mateToBall + 5 < myToBall then
		self:move(ballPos:Lerp(ownGoal.center, 0.4), dt)
		return
	end

	-- 6) FEINTE : l'adversaire charge la balle → il s'arrête, le laisse taper dans le vide
	if now < self.fakeUntil then
		self:hold()
		if ballVel.Magnitude > 25 then self.fakeUntil = 0 end -- l'adversaire a touché, on reprend
		return
	end
	if opp and oppToBall < 12 and myToBall > 6 and myToBall < 18 and now > self.nextFakeCheck then
		self.nextFakeCheck = now + 2
		local oppSpeedToBall = opp.root.AssemblyLinearVelocity:Dot(flat(ballPos - opp.root.Position))
		if oppSpeedToBall > 15 and math.random() < SETTINGS.FakeChance then
			self.fakeUntil = now + SETTINGS.FakeDuration
			self:hold()
			return
		end
	end

	-- 7) 50/50 AGRESSIF avec dash
	if opp and oppToBall < 10 and myToBall - oppToBall < SETTINGS.ChallengeMargin then
		self:move(ballPos, dt, true)
		if myToBall < 12 then self:dash(flat(ballPos - myPos)) end
		if myToBall <= SETTINGS.KickRange * 1.3 then
			self:hit(ball, toGoal, SETTINGS.ChallengePower, 8)
		end
		return
	end

	-- 8) ROTATION / SHADOW DÉFENSE : l'adversaire a la balle dans notre moitié
	local ballInOurHalf = (ballPos - ownGoal.center).Magnitude < (ballPos - targetGoal.center).Magnitude
	if opp and oppToBall < myToBall and ballInOurHalf then
		local outOfPlay = (myPos - ownGoal.center).Magnitude > (ballPos - ownGoal.center).Magnitude
		if outOfPlay then
			self:move(ownGoal.center, dt, true) -- rotation rapide vers son but
		else
			self:move(ownGoal.center:Lerp(ballPos, SETTINGS.DefenseLine), dt)
		end
		return
	end

	-- 9) ATTAQUE : lit la trajectoire et arrive derrière la balle, face au but adverse
	local t = math.clamp(myToBall / humanoid.WalkSpeed, 0, 1.5)
	local predicted = ballPos + Vector3.new(ballVel.X, 0, ballVel.Z) * t
	if myToBall > 8 then
		self:move(predicted - flat(targetGoal.center - predicted) * 3, dt)
	else
		self:move(predicted, dt)
	end
end

-- ===== [ GESTION DES ÉQUIPES (1v1 / 2v2 / 3v3) ] =====
local function countHumans(teamKey)
	local n = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		if teamOf(plr) == teamKey then n += 1 end
	end
	return n
end

-- Ajoute / retire des bots pour que chaque équipe ait exactement "mode" joueurs
local function rebalance()
	for _, teamKey in ipairs(TEAM_KEYS) do
		local list = botsByTeam[teamKey]
		local wanted = enabled and math.max(0, mode - countHumans(teamKey)) or 0
		while #list > wanted do
			table.remove(list):despawn()
		end
		while #list < wanted do
			local bot = Bot.new(teamKey, #list + 1)
			bot:spawn()
			table.insert(list, bot)
		end
	end

	allBots = {}
	for _, teamKey in ipairs(TEAM_KEYS) do
		for _, bot in ipairs(botsByTeam[teamKey]) do
			table.insert(allBots, bot)
		end
	end
end

-- ===== [ TOUCHES K / M (via RemoteEvent) ] =====
local remote = ReplicatedStorage:FindFirstChild("ZenBotControl")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "ZenBotControl"
	remote.Parent = ReplicatedStorage
end

local function isAdmin(player)
	if RunService:IsStudio() then return true end
	if table.find(SETTINGS.Admins, player.UserId) then return true end
	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end
	local ok, rank = pcall(function() return player:GetRankInGroup(game.CreatorId) end)
	return ok and rank >= 255 -- propriétaire du groupe
end

local function statusText()
	return string.format("Bots %s • %dv%d • niveau %s",
		enabled and "ACTIVÉS" or "DÉSACTIVÉS", mode, mode, SETTINGS.Level)
end

remote.OnServerEvent:Connect(function(player, action)
	if not isAdmin(player) then
		remote:FireClient(player, "Tu n'as pas la permission de contrôler les bots.")
		return
	end
	if action == "toggle" then
		enabled = not enabled
	elseif action == "mode" then
		mode = mode % 3 + 1
	else
		return
	end
	needRebalance = true
	remote:FireAllClients(statusText())
end)

-- Rééquilibre quand un joueur arrive, part ou change d'équipe
local function watchPlayer(player)
	player:GetPropertyChangedSignal("Team"):Connect(function() needRebalance = true end)
	needRebalance = true
end
Players.PlayerAdded:Connect(watchPlayer)
Players.PlayerRemoving:Connect(function() needRebalance = true end)
for _, player in ipairs(Players:GetPlayers()) do watchPlayer(player) end

-- ===== [ DÉMARRAGE ] =====
-- Attend que la balle et les buts existent, et prévient dans l'Output sinon
local function waitForSetup()
	local needed = { SETTINGS.BallName, SETTINGS.BlueGoalName, SETTINGS.OrangeGoalName }
	local warnAt = os.clock() + SETTINGS.SetupWarnDelay
	while true do
		local missing = {}
		for _, name in ipairs(needed) do
			if not findCached(name) then table.insert(missing, name) end
		end
		local ball = findCached(SETTINGS.BallName)
		if #missing == 0 then
			if ball:IsA("BasePart") then return ball end
			if os.clock() > warnAt then
				warn("[ZenBot] '" .. SETTINGS.BallName .. "' doit être une Part (sphère), pas un " .. ball.ClassName)
				warnAt = os.clock() + SETTINGS.SetupWarnDelay
			end
		elseif os.clock() > warnAt then
			warn("[ZenBot] Introuvable dans le workspace : " .. table.concat(missing, ", ")
				.. " → renomme tes objets ou change les noms en haut du script.")
			warnAt = os.clock() + SETTINGS.SetupWarnDelay
		end
		task.wait(0.5)
	end
end

local ballSpawn = waitForSetup().Position
print("[ZenBot] Prêt • " .. statusText() .. " • K = activer/désactiver, M = changer de mode")

local lastRebalance = 0
while true do
	local dt = task.wait(SETTINGS.ThinkRate)

	if needRebalance or os.clock() - lastRebalance > 2 then
		needRebalance = false
		lastRebalance = os.clock()
		rebalance()
	end

	local ball = findCached(SETTINGS.BallName)
	if ball and ball:IsA("BasePart") and #allBots > 0 then
		local ctx = {
			ball = ball,
			ballSpawn = ballSpawn,
			actors = getActors(),
			goals = {
				[SETTINGS.BlueGoalName] = getGoalInfo(findCached(SETTINGS.BlueGoalName)),
				[SETTINGS.OrangeGoalName] = getGoalInfo(findCached(SETTINGS.OrangeGoalName)),
			},
		}

		for _, bot in ipairs(allBots) do
			if bot:alive() then
				local ok, err = pcall(bot.think, bot, dt, ctx)
				if not ok then warn("[ZenBot] " .. tostring(err)) end
			elseif not bot.diedAt then
				bot.diedAt = os.clock()
			elseif os.clock() - bot.diedAt > SETTINGS.RespawnDelay then
				bot:despawn()
				bot:spawn()
			end
		end
	end

	-- Rend la balle à la physique normale 1 s après la dernière touche d'un bot
	if ball and lastServerTouch > 0 and os.clock() - lastServerTouch > 1 then
		pcall(function() ball:SetNetworkOwnershipAuto() end)
		lastServerTouch = 0
	end
end
