-- ===== [ ZEN-BOT : TOUCHES DE CONTRÔLE ] =====
-- LocalScript à mettre dans StarterPlayerScripts.
-- Envoie les touches au serveur (ZenBot.server.lua) qui vérifie si tu as le droit.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local TOGGLE_KEY = Enum.KeyCode.K -- active / désactive les bots
local MODE_KEY = Enum.KeyCode.M   -- 1v1 → 2v2 → 3v3

local remote = ReplicatedStorage:WaitForChild("ZenBotControl")

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end -- ignore si tu tapes dans le chat
	if input.KeyCode == TOGGLE_KEY then
		remote:FireServer("toggle")
	elseif input.KeyCode == MODE_KEY then
		remote:FireServer("mode")
	end
end)

-- Affiche l'état des bots en notification
remote.OnClientEvent:Connect(function(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "ZenBot", Text = text, Duration = 3 })
	end)
end)
