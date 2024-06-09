--[[
  This Module script is part of many other scripts that work together to make the whole game function properly.
]]
--// SERVICES
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--// VARIABLES
local game_models = ServerStorage["game models"]
local guis = ReplicatedFirst.Guis

local current_map = workspace.CurrentMap

local remotes = ReplicatedStorage.Remotes
local events = remotes.Events

local SETTINGS = require(ReplicatedStorage.SETTINGS)
local Logic = require(ServerScriptService.Modules.Logic_Module)
local Data_Handler = require(script.Parent.Data)

local module = {}

local player_repairing_gen = {}
local skillcheck_penalty = SETTINGS.GENERATOR_SETTINGS.FAIL_PENALTY

--// FUNCTIONS
module.__index = module

-- Function that opens the escape doors
local function open_door()
	local map = current_map:GetChildren()[1]
	if map == nil then warn("Unexpected behavior : attempted to open the door model when there is no map.") return end
	for _, child in map:GetChildren() do
		if child.Name == "escape_model" then
			local animation = child.AnimationController.Animator:LoadAnimation(child.open)
			animation:Play()
			task.wait(.6)
			animation:AdjustSpeed(0) -- Animation makes the doors open, its paused so that the doors can remained open forever.
		end
	end	
end

-- create a new generator class
function module.new(cf, name)
	local generator = {}
	setmetatable(generator, module)
	
	--set up model and positioning
	generator.model = game_models["New Generator"]:Clone()
	generator.model.Name = name
	generator.model.Parent = workspace
	generator.model:PivotTo(cf)
	
	--set up values
	generator.progress = 0
	generator.max_progress = SETTINGS.GENERATOR_SETTINGS.GEN_MAX
	generator.can_progress = true --if we want to stop the generator from progressing like if the player messes up a skill check or a monster ability
	generator.repaired = false
	generator.active_players = {}
	
	--load animations
	generator.repair_anim = generator.model.AnimationController.Animator:LoadAnimation(generator.model.repairing)
	generator.repaired_anim = generator.model.AnimationController.Animator:LoadAnimation(generator.model.repaired)
	
	generator.repair_anim:Play()
	generator.repair_anim:AdjustSpeed(0) -- Repair animation's speed is supposed to increase based on the amount of progress
	
	return generator
end

-- Function that makes the player stop repairing the generator
function quit_repair(player)
	if CollectionService:HasTag(player, 'repairing') then
		CollectionService:RemoveTag(player, 'repairing')
		
		local character, humanoid = Logic.GetCharacterAndHumanoid(player) -- Module function that returns the character and humanoid of the player provided
		
		--remove progress ui
		Logic.DeleteGui(player, 'generator_progress_ui')

		--stop repairing animation
		ReplicatedStorage.Remotes.Events.PlayAnimation:FireClient(player, 'Repair')
		humanoid.WalkSpeed = SETTINGS.SURVIVOR_SETTINGS.WALK_SPEED
		
		--remove player from table
		local prompt = player_repairing_gen[player]
		if prompt then
			prompt.Enabled = true
		end

		player_repairing_gen[player] = nil
	end
end

-- Function that sets back generator progress and delays repairing
function module:fail(prompt, player)
	self.can_progress = false

	task.delay(2, function()
		self.can_progress = true
	end)

	ReplicatedStorage.Remotes.Events.PlayAnimation:FireClient(player, 'Repair_fail')
	self.progress = self.progress - skillcheck_penalty

	if self.progress < 0 then
		self.progress = 0
	end

  -- VFXs
	local particle_part = prompt.Parent.particle_part.Value
	local explosion = particle_part.VFXSpark.explosion
	local shards = particle_part.VFXSpark.shards
	local sparks = particle_part.VFXSpark.sparks
	local attachment = particle_part.Attachment
	
	--notify monster of gen
	local monster = game.Teams.Monster:GetPlayers()[1] 
	events.Highlight:FireClient(monster, self.model, SETTINGS.GENERATOR_SETTINGS.NOTIF_DUR, SETTINGS.GENERATOR_SETTINGS.HIGHLIGHT_PROPS) -- A client-sided script will take in these parameters to highlight the generator model
	
	--play vfx
	particle_part.sfx:Play()
	task.wait(.01)

	explosion:Emit(explosion:GetAttribute("EmitCount"))
	shards:Emit(shards:GetAttribute("EmitCount"))
	sparks:Emit(sparks:GetAttribute("EmitCount"))

	TweenService:Create(attachment.PointLight, TweenInfo.new(.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Brightness = 5}):Play()
	task.wait(.1)
	TweenService:Create(attachment.PointLight, TweenInfo.new(.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Brightness = 0}):Play()
end

function module:repair(prompt, player)
	
	if ReplicatedStorage.generators_repaired.Value >= SETTINGS.GENERATOR_SETTINGS.REQUIRED then return end --already repaired required gens
	--check if theres already 2 players actively working on the generator
	if #self.active_players == 2 then return end --can't repair when spots are taken
	if self.repaired == true then return end --generator is already repaired
	if CollectionService:HasTag(player, 'repairing') then return end --player is already repairing a gen
	if player.Team ~= game.Teams.Survivors then return end
	
	--check if this prompt is already in use
	for user, active_prompt in player_repairing_gen do
		if active_prompt == prompt then
			--player is attempting to use a prompt that can't be used; possible exploiter
			player:Kick("Unexpected behaviour : attempted to used disabled prompt")
		end
	end
	
	print(player.Name .. " is repairing this generator.")
	local character = player.Character
	local humanoidrootpart = character.PrimaryPart
	local position_part = prompt.Parent.position_part.Value
	
	humanoidrootpart.CFrame = position_part.CFrame -- Moves player to correct positioning
	CollectionService:AddTag(player, "repairing")
	table.insert(self.active_players, player)
	
	ReplicatedStorage.Remotes.Events.PlayAnimation:FireClient(player, 'Repair')
	prompt.Enabled = false
	
	--give progress ui
	local progress_ui = guis.generator_progress_ui:Clone()
	progress_ui.Parent = player.PlayerGui
	
	if #self.active_players == 2 then return end --dont create another repair loop
  
	player_repairing_gen[player] = prompt
	
	local repair_connection
	repair_connection = task.spawn(function()
		while self.repaired == false and #self.active_players > 0 do -- Continue when the generator is not fully repaired AND there is at least 1 player repairing it
			--update active players table
			for _, active in self.active_players do
				if CollectionService:HasTag(active, 'repairing') == false then
					table.remove(self.active_players, table.find(self.active_players, active))
					continue
				end
				
				--update progress on their end
				events.repair_progress:FireClient(active, self.progress, self.max_progress)
			end
			
			if #self.active_players == 0 then 
				break --no players are repairing the gen
			end 
			
			--check if the generator has reached the goal progress
			if self.progress >= self.max_progress then
				self.repaired = true
				self.repair_anim:Stop()
				self.repaired_anim:Play()
				print("generator is repaired")
				
				local highlight = self.model:FindFirstChild("Highlight")
				if highlight then
					highlight:Destroy()
				end
                -- Remove prompts 
				self.model.prompt_part1:Destroy()
				self.model.prompt_part2:Destroy()
				-- Update count
				ReplicatedStorage.generators_repaired.Value = ReplicatedStorage.generators_repaired.Value + 1
				-- Open door when # of gens required to open is met
				if ReplicatedStorage.generators_repaired.Value >= SETTINGS.GENERATOR_SETTINGS.REQUIRED then
					open_door()
				end
				-- Reward players and make them stop repairing
				for _, active in self.active_players do
					Data_Handler.GiveCurrency(active, SETTINGS.CURRENCY_SETTINGS.CURRENCY_PER_REPAIRED_GENERATOR)
					quit_repair(active)
				end
				
				break
			end
	        task.wait(.1)
			if self.can_progress == false then continue end -- Don't do anything if the generator can't progress
            
			local PlayerConfig = Logic.Get_Player_Settings(player)	-- Gets a list of game stats of the player 	
			self.progress = self.progress + (SETTINGS.GENERATOR_SETTINGS.INCREMENT * PlayerConfig.REPAIR_INCREASE * #self.active_players) -- increase progress; will vary if player's repairing speed differs and how many players are repairing the gen at the same time
			
			--update repair anim
			local speed = (self.progress / self.max_progress) * 2
			self.repair_anim:AdjustSpeed(speed)
			
			--give players a skill check
			task.spawn(function()
				for i, repairing_player in self.active_players do
					
					if repairing_player and repairing_player:IsDescendantOf(Players) then else 
						table.remove(self.active_players, i) -- Remove players who aren't in the game
					end
					
					if CollectionService:HasTag(repairing_player, 'skillcheck cooldown') then continue end -- On a cooldown to receive a skill check
					if self.repaired == true then quit_repair(repairing_player) continue end -- Generator is repaired
					
					--skillcheck chance
					local num = math.random(1,30)

					if num == 1 then
						CollectionService:AddTag(repairing_player, 'skillcheck cooldown')
						
						local old = repairing_player.Character.Humanoid.WalkSpeed
						repairing_player.Character.Humanoid.WalkSpeed = 0
						
						--give ui
						local random_int = math.random(1,2)
						local ui = guis:FindFirstChild('skillcheck' .. tostring(random_int)):Clone()
						ui.Parent = repairing_player.PlayerGui
						ui.LocalScript.Enabled = true
						
						task.wait(.1)
						
						local result = nil

						local success, err = pcall(function()
							local t = 0 -- seconds spent on the skill check
							local timeout = 15 -- time before player should be kicked for suspicious behavior
							
							events.skillcheck:FireClient(repairing_player, 5) -- sends the skill check, 5 seconds is the duration they have to complete
							
							local connection
							connection = events.skillcheck.OnServerEvent:Connect(function(sender, boolean)
								if sender ~= repairing_player then return end -- sender should be the player who is repairing and is receiving the skill check
								if typeof(boolean) == 'boolean' then -- if the boolean sent is actually a boolean
									result = boolean
									connection:Disconnect()
									connection = nil
								end
							end)

							repeat
								task.wait(.05)
								t += .05
							until t >= timeout or result ~= nil or CollectionService:HasTag(repairing_player, 'repairing') == false or self.repaired == true -- wait until timeout is reached OR result is sent back OR the player stopped repairing OR the generator is done
							-- destroy ui if it exists
							if ui then 
								ui:Destroy()
							end
							-- disable connection if still running
							if connection then
								connection:Disconnect()
								connection = nil
							end
							-- don't do anything if the generator is repaired
							if self.repaired == true then
								CollectionService:RemoveTag(repairing_player, 'skillcheck cooldown')
								
								quit_repair(repairing_player)
								return
							end
                            
							task.delay(.2, function()
								if repairing_player then
									repairing_player.Character.Humanoid.WalkSpeed = old
								end
							end)
							
							task.delay(3, function() -- player is on cooldown for skill checks for 3 seconds
								CollectionService:RemoveTag(repairing_player, 'skillcheck cooldown')
							end)
							
							if result ~= nil then
								if result == false then -- Player failed the skill check
									self:fail(prompt, repairing_player)
								end								
							else
								if CollectionService:HasTag(repairing_player, 'repairing') == false then -- Player stopped repairing the generator during a skill check; skill check is automatically failed
									self:fail(prompt, repairing_player)
									
									--remove the skill check ui if they still have it
									if repairing_player.PlayerGui:FindFirstChild('skillcheck1') then
										repairing_player.PlayerGui:FindFirstChild('skillcheck1'):Destroy()
                                    elseif repairing_player.PlayerGui:FindFirstChild('skillcheck2') then
										repairing_player.PlayerGui:FindFirstChild('skillcheck2'):Destroy()
									end
									
								else
									warn(player.Name .. " took too long to respond to the skillcheck.")
									-- repairing_player:Kick("Unexpected behaviour : timeout reached")  | Temporarily commented to prevent laggy players from being kicked.
								end
							end
							return
						end)
						if err then -- Debug
							print(success)
							print(err)
						end
					end
				end
			end)
		end
	end)
end
-- Function destroys the generator class when no longer used
function module:Destroy()
	setmetatable(self, nil)
	table.clear(self)
	table.freeze(self)
end

--// INITIALIZE
RunService.Heartbeat:Connect(function()
	for _, player in pairs(Players:GetPlayers()) do
		local character = player.Character 
		if character then else continue end
		
		if character.Humanoid.MoveDirection.Magnitude > 0 and character.Humanoid.WalkSpeed > 0 then 
			--check if they have repair tags
            if CollectionService:HasTag(player, "repairing") then
                quit_repair(player)   
            end
		end
	end
end)

return module
