getgenv().boardSettings = {
    UseGoldenDice = true,
    GoldenDiceDistance = 1,
    DiceDistance = 6,
    GiantDiceDistance = 10,
}
getgenv().remainingItems = {}
loadstring(game:HttpGet("https://raw.githubusercontent.com/IdiotHub/Scripts/refs/heads/main/BGSI/main.lua"))()

if not game:IsLoaded() then
    game.Loaded:Wait()
end
task.wait(0.5)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local LocalDataModule = ReplicatedStorage:WaitForChild("Client"):WaitForChild("Framework"):WaitForChild("Services"):WaitForChild("LocalData")
local RemoteEventPath = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Framework"):WaitForChild("Network"):WaitForChild("Remote"):WaitForChild("RemoteEvent")

local LocalData = require(LocalDataModule)

local PET_DELETION_INTERVAL = 10

local function deleteSpecificPets()
    local playerData = LocalData:Get()

    if not playerData or not playerData.Pets then
        return
    end

    local petId_Golem_MythicOnly = nil
    local petId_Golem_MythicAndShiny = nil
    local petId_Unicorn_MythicOnly = nil
    local petId_Unicorn_MythicAndShiny = nil

    local foundGolem_MythicOnly_flag = false
    local foundGolem_MythicAndShiny_flag = false
    local foundUnicorn_MythicOnly_flag = false
    local foundUnicorn_MythicAndShiny_flag = false

    for _, petInstanceData in ipairs(playerData.Pets) do
        local petName = petInstanceData.Name
        local isMythic = petInstanceData.Mythic == true
        local isShiny = petInstanceData.Shiny == true
        local petID = petInstanceData.Id

        if petName == "Emerald Golem" then
            if isMythic and not isShiny and not foundGolem_MythicOnly_flag then
                petId_Golem_MythicOnly = petID
                foundGolem_MythicOnly_flag = true
            elseif isMythic and isShiny and not foundGolem_MythicAndShiny_flag then
                petId_Golem_MythicAndShiny = petID
                foundGolem_MythicAndShiny_flag = true
            end
        elseif petName == "Crystal Unicorn" then
            if isMythic and not isShiny and not foundUnicorn_MythicOnly_flag then
                petId_Unicorn_MythicOnly = petID
                foundUnicorn_MythicOnly_flag = true
            elseif isMythic and isShiny and not foundUnicorn_MythicAndShiny_flag then
                petId_Unicorn_MythicAndShiny = petID
                foundUnicorn_MythicAndShiny_flag = true
            end
        end

        if foundGolem_MythicOnly_flag and foundGolem_MythicAndShiny_flag and foundUnicorn_MythicOnly_flag and foundUnicorn_MythicAndShiny_flag then
            break 
        end
    end

    local function tryDeletePet(petId)
        if petId then
            local deleteArgs = { "DeletePet", petId, 1, false }
            pcall(function() RemoteEventPath:FireServer(unpack(deleteArgs)) end)
        end
    end

    tryDeletePet(petId_Golem_MythicOnly)
    tryDeletePet(petId_Golem_MythicAndShiny)
    tryDeletePet(petId_Unicorn_MythicOnly)
    tryDeletePet(petId_Unicorn_MythicAndShiny)
end

task.spawn(function()
    while true do
        deleteSpecificPets()
        task.wait(PET_DELETION_INTERVAL)
    end
end)