local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WEBSOCKET_SERVER_URL = "ws://192.168.0.225:8080" -- Ensure this is your PC's local IP where Sniper is running
local RECONNECT_DELAY = 7
local PING_INTERVAL = 25

local ws_client
local instanceIdFromServer = nil
local is_connected = false
local last_ping_sent = 0
local connection_attempt_active = false

-- Keep _try_attach_event and _try_send_message as they are from your original script
local function _try_attach_event(client, event_config, callback)
    local s_access, prop, s_connect_access, connect_fn, s_call, err_call
    s_access, prop = pcall(function() return client[event_config.PascalEvent] end)
    if s_access and prop and type(prop) == "table" then
        s_connect_access, connect_fn = pcall(function() return prop.Connect end)
        if s_connect_access and connect_fn and type(connect_fn) == "function" then
            s_call, err_call = pcall(function() prop:Connect(callback) end)
            if s_call then return true, event_config.PascalEvent .. ":Connect" end
        end
    end
    s_access, prop = pcall(function() return client[event_config.snake_event] end)
    if s_access and prop and type(prop) == "table" then
        s_connect_access, connect_fn = pcall(function() return prop.connect end)
        if s_connect_access and connect_fn and type(connect_fn) == "function" then
            s_call, err_call = pcall(function() prop:connect(callback) end)
            if s_call then return true, event_config.snake_event .. ":connect" end
        end
    end
    s_access, prop = pcall(function() return client.on end)
    if s_access and prop and type(prop) == "function" then
        s_call, err_call = pcall(function() client:on(event_config.emitter_event, callback) end)
        if s_call then return true, "client:on('" .. event_config.emitter_event .. "')" end
    end
    if event_config.direct_on_event then
        s_call, err_call = pcall(function() client[event_config.direct_on_event] = callback end)
        if s_call then 
            s_access, prop = pcall(function() return client[event_config.direct_on_event] end)
            if s_access and type(prop) == "function" then return true, "." .. event_config.direct_on_event end
        end
    end
    if event_config.direct_on_underscore_event then
        s_call, err_call = pcall(function() client[event_config.direct_on_underscore_event] = callback end)
        if s_call then
            s_access, prop = pcall(function() return client[event_config.direct_on_underscore_event] end)
            if s_access and type(prop) == "function" then return true, "." .. event_config.direct_on_underscore_event end
        end
    end
    return false
end

local function _try_send_message(client, data_string)
    local success, err_msg, method_name
    method_name = "client:send()"
    success, err_msg = pcall(function() client:send(data_string) end)
    if success then return true, method_name end
    method_name = "client.send()"
    success, err_msg = pcall(function() client.send(data_string) end)
    if success then return true, method_name end
    method_name = "client:Send()"
    success, err_msg = pcall(function() client:Send(data_string) end)
    if success then return true, method_name end
    method_name = "client.Send()"
    success, err_msg = pcall(function() client.Send(data_string) end)
    if success then return true, method_name end
    return false, err_msg 
end


local function send_ws_message(data_table)
    if not (ws_client and (is_connected or data_table.type == "identity_report")) then
        if not (data_table.type == "identity_report" and ws_client) then
            warn("[SNIPER_LUA_WS] Not sending message: WS client not ready or not connected. Type: " .. (data_table.type or "N/A"))
            return
        end
    end
    local success_json, json_data = pcall(HttpService.JSONEncode, HttpService, data_table)
    if not success_json or not ws_client then
        if not success_json then warn("[SNIPER_LUA_WS] JSONEncode failed: " .. tostring(json_data)) end
        if not ws_client then warn("[SNIPER_LUA_WS] WS client is nil, cannot send.") end
        return
    end
    local sent, method_or_error = _try_send_message(ws_client, json_data)
    if not sent then
        warn("[SNIPER_LUA_WS] All WebSocket send methods failed. Last error: " .. tostring(method_or_error))
    else
        -- warn("[SNIPER_LUA_WS] Successfully sent WS message of type: " .. data_table.type)
    end
end

local function send_identity_report()
    if not Players.LocalPlayer then
        warn("[SNIPER_LUA_ID] LocalPlayer not available for identity report. Will retry.")
        task.wait(1)
        if not Players.LocalPlayer then
            warn("[SNIPER_LUA_ID] LocalPlayer still not available after retry.")
            return
        end
    end
    local userId = Players.LocalPlayer.UserId
    local userName = Players.LocalPlayer.Name
    if userId and userName then
        warn("[SNIPER_LUA_ID] Sending identity report for UserID: " .. userId .. ", UserName: " .. userName)
        send_ws_message({
            type = "identity_report",
            userId = tostring(userId),
            userName = userName
        })
    else
        warn("[SNIPER_LUA_ID] Could not send identity report: UserId or UserName missing.")
    end
end

local function handle_server_message(message_string)
    -- warn("[SNIPER_LUA_WS] Raw message received: " .. message_string)
    local success, data = pcall(HttpService.JSONDecode, HttpService, message_string)
    if not success then
        warn("[SNIPER_LUA_WS] Failed to decode JSON message: " .. message_string .. " Error: " .. tostring(data))
        return
    end

    if data.type == "connected" then
        warn("[SNIPER_LUA_WS] Received 'connected' from server. InstanceID: " .. (data.instanceId or "N/A"))
        instanceIdFromServer = data.instanceId
        is_connected = true
        local server_tells_us_status = data.status
        if server_tells_us_status == 'idle' then
            send_ws_message({ type = "status_update", status = "idle" })
        elseif not server_tells_us_status and not (server_tells_us_status == "active_cooldown" or server_tells_us_status == "teleport_sent_awaiting_disconnect" or server_tells_us_status == "teleport_initiated_awaiting_reconnect") then
             send_ws_message({ type = "status_update", status = "idle" })
        end
    elseif data.type == "teleport" then
        warn("[SNIPER_LUA_TP] Received 'teleport' command. PlaceID: " .. (data.placeId or "N/A") .. ", JobID: " .. (data.jobId or "N/A"))
        local placeId = tonumber(data.placeId)
        local jobId = tostring(data.jobId)
        if placeId and jobId and Players.LocalPlayer then
            send_ws_message({ type = "status_update", status = "joining_game", placeId = placeId, jobId = jobId })
            TeleportService:TeleportToPlaceInstance(placeId, jobId, Players.LocalPlayer)
        else
            warn("[SNIPER_LUA_TP] Teleport command invalid or LocalPlayer missing.")
        end
    elseif data.type == "ping" then
        -- warn("[SNIPER_LUA_WS] Received ping, sending pong.")
        send_ws_message({ type = "pong" })
    elseif data.type == "error" and data.message == "Identity not established." then
        warn("[SNIPER_LUA_WS] Received 'Identity not established' error. Resending identity.")
        send_identity_report()
    elseif data.type == "send_chat_to_roblox" and data.message then
        warn("[SNIPER_LUA_CHAT] Received 'send_chat_to_roblox': ", HttpService:JSONEncode(data))
        local messageToSend = tostring(data.message)
        local messageSent = false

        if TextChatService then
            warn("[SNIPER_LUA_CHAT] TextChatService found. Attempting to send: ", messageToSend)
            local targetChannel = nil
            
            if TextChatService:FindFirstChild("ChatInputBarConfiguration") then
                local inputBarConfig = TextChatService.ChatInputBarConfiguration
                targetChannel = inputBarConfig:GetAttribute("TargetTextChannel") or inputBarConfig.TargetTextChannel
                if targetChannel and targetChannel:IsA("TextChannel") then
                    warn("[SNIPER_LUA_CHAT] Using ChatInputBarConfiguration. TargetChannel: " .. targetChannel.Name)
                    local s, e = pcall(function() targetChannel:SendAsync(messageToSend) end)
                    if s then
                        warn("[SNIPER_LUA_CHAT] Successfully sent chat via InputBar TargetChannel: " .. targetChannel.Name)
                        send_ws_message({type="feedback", status="success", message="Lua: Sent chat (InputBar Target) to '" .. targetChannel.Name .. "'."})
                        messageSent = true
                    else
                        warn("[SNIPER_LUA_CHAT] Failed to send via ChatInputBarConfiguration TargetChannel (" .. targetChannel.Name .. "): " .. tostring(e))
                        send_ws_message({type="feedback", status="error", message="Lua: Failed InputBar Target '" .. targetChannel.Name .. "': " .. tostring(e)})
                    end
                else
                    warn("[SNIPER_LUA_CHAT] ChatInputBarConfiguration TargetTextChannel invalid or not found.")
                end
            else
                 warn("[SNIPER_LUA_CHAT] ChatInputBarConfiguration not found in TextChatService.")
            end

            if not messageSent then
                warn("[SNIPER_LUA_CHAT] Falling back to general channel search for TextChatService.")
                local channels = TextChatService:GetChildren()
                local preferredChannel = nil
                for _, channel in ipairs(channels) do
                    if channel:IsA("TextChannel") then
                        if string.lower(channel.Name) == "rbxsystem" or string.lower(channel.Name) == "all" or string.find(string.lower(channel.Name), "general") then
                            preferredChannel = channel
                            break
                        end
                    end
                end
                
                if not preferredChannel then 
                    for _, channel in ipairs(channels) do
                        if channel:IsA("TextChannel") then
                            preferredChannel = channel
                            break
                        end
                    end
                end

                if preferredChannel then
                    warn("[SNIPER_LUA_CHAT] Attempting SendAsync on fallback channel: " .. preferredChannel.Name)
                    local s, e = pcall(function() preferredChannel:SendAsync(messageToSend) end)
                    if s then
                        warn("[SNIPER_LUA_CHAT] Successfully sent chat via fallback TextChatService channel: " .. preferredChannel.Name)
                        send_ws_message({type="feedback", status="success", message="Lua: Sent chat (Fallback TCS) to '" .. preferredChannel.Name .. "'."})
                        messageSent = true
                    else
                        warn("[SNIPER_LUA_CHAT] Failed to send chat via fallback TextChatService channel (" .. preferredChannel.Name .. "): " .. tostring(e))
                        send_ws_message({type="feedback", status="error", message="Lua: Failed Fallback TCS '" .. preferredChannel.Name .. "': " .. tostring(e)})
                    end
                else
                    warn("[SNIPER_LUA_CHAT] No suitable TextChannel found via fallback search.")
                    send_ws_message({type="feedback", status="error", message="Lua: No TextChannel found (fallback)."})
                end
            end
        end

        if not messageSent then
            warn("[SNIPER_LUA_CHAT] TextChatService send failed or not available. Attempting legacy Chat service.")
            local ChatService = game:GetService("Chat")
            if ChatService and Players.LocalPlayer and Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChild("Head") then
                warn("[SNIPER_LUA_CHAT] Attempting ChatService:Chat() for: ", messageToSend)
                local s, e = pcall(function() ChatService:Chat(Players.LocalPlayer.Character.Head, messageToSend, Enum.ChatColor.Blue) end)
                if s then
                    warn("[SNIPER_LUA_CHAT] Successfully sent chat via legacy ChatService.")
                    send_ws_message({type="feedback", status="success", message="Lua: Sent chat (Legacy)."})
                    messageSent = true
                else
                    warn("[SNIPER_LUA_CHAT] Failed to send chat via legacy ChatService: " .. tostring(e))
                    send_ws_message({type="feedback", status="error", message="Lua: Failed Legacy Chat: " .. tostring(e)})
                end
            else
                warn("[SNIPER_LUA_CHAT] Legacy ChatService not usable (missing service, player, character, or head).")
                if not messageSent then 
                     send_ws_message({type="feedback", status="error", message="Lua: All chat send methods failed."})
                end
            end
        end
    end
end

local function setup_chat_listeners()
    if TextChatService then
        warn("[SNIPER_LUA_CHAT_LISTEN] Setting up TextChatService.MessageReceived listener.")
        TextChatService.MessageReceived:Connect(function(textChatMessage)
            warn("[SNIPER_LUA_CHAT_LISTEN] TextChatService.MessageReceived Fired. Text: ", textChatMessage.Text, " Source: ", textChatMessage.TextSource and textChatMessage.TextSource.Name or "System")
            if not is_connected then
                warn("[SNIPER_LUA_CHAT_LISTEN] MessageReceived, but not connected to WS. Aborting send.")
                return
            end
            
            local authorUserId = "System"
            local authorDisplayName = "System" 
            local messageText = textChatMessage.Text
            
            local timestamp
            if textChatMessage.Timestamp and typeof(textChatMessage.Timestamp) == "DateTime" then
                if textChatMessage.Timestamp.UnixTimestampMillis then
                    timestamp = math.floor(textChatMessage.Timestamp.UnixTimestampMillis / 1000)
                    warn("[SNIPER_LUA_CHAT_LISTEN] Got UnixTimestampMillis: ", textChatMessage.Timestamp.UnixTimestampMillis, " -> Seconds: ", timestamp)
                elseif textChatMessage.Timestamp.UnixTimestamp then
                    timestamp = textChatMessage.Timestamp.UnixTimestamp
                    warn("[SNIPER_LUA_CHAT_LISTEN] Got UnixTimestamp (seconds): ", timestamp)
                else
                    warn("[SNIPER_LUA_CHAT_LISTEN] DateTime object present, but no UnixTimestampMillis or UnixTimestamp property found. Using os.time().")
                    timestamp = os.time() 
                end
            else
                warn("[SNIPER_LUA_CHAT_LISTEN] textChatMessage.Timestamp is not a DateTime object or is nil. Using os.time(). Type was: ", typeof(textChatMessage.Timestamp))
                timestamp = os.time() 
            end

            if textChatMessage.TextSource then 
                authorUserId = tostring(textChatMessage.TextSource.UserId)
                authorDisplayName = textChatMessage.TextSource.Name 
                if textChatMessage.TextSource.DisplayName and textChatMessage.TextSource.DisplayName ~= "" then
                    authorDisplayName = textChatMessage.TextSource.DisplayName
                end
            end
            
            local payload = {
                type = "chat_message_from_client",
                authorUserId = authorUserId,
                authorDisplayName = authorDisplayName,
                message = messageText,
                timestamp = timestamp
            }
            warn("[SNIPER_LUA_CHAT_LISTEN] Sending to Sniper (TCS): ", HttpService:JSONEncode(payload))
            send_ws_message(payload)
        end)
    else
        warn("[SNIPER_LUA_CHAT_LISTEN] TextChatService not found. Setting up legacy chat listeners.")
        local function handle_legacy_chat(player, message, eventType)
            warn("[SNIPER_LUA_CHAT_LISTEN] Legacy Chat ("..eventType..") Fired. Player: " .. player.Name .. ", Message: " .. message)
            if not is_connected then
                warn("[SNIPER_LUA_CHAT_LISTEN] Legacy chat, but not connected to WS. Aborting send.")
                return
            end
            local payload = {
                type = "chat_message_from_client",
                authorUserId = tostring(player.UserId),
                authorDisplayName = player.Name, 
                message = message,
                timestamp = os.time()
            }
            if player.DisplayName and player.DisplayName ~= "" then
                 payload.authorDisplayName = player.DisplayName
            end
            warn("[SNIPER_LUA_CHAT_LISTEN] Sending to Sniper (Legacy): ", HttpService:JSONEncode(payload))
            send_ws_message(payload)
        end

        Players.PlayerAdded:Connect(function(player)
            warn("[SNIPER_LUA_CHAT_LISTEN] PlayerAdded: " .. player.Name .. ". Connecting Chatted event.")
            player.Chatted:Connect(function(message) handle_legacy_chat(player, message, "PlayerAdded.Chatted") end)
        end)
        for _, player in ipairs(Players:GetPlayers()) do
            warn("[SNIPER_LUA_CHAT_LISTEN] Existing Player: " .. player.Name .. ". Connecting Chatted event.")
            player.Chatted:Connect(function(message) handle_legacy_chat(player, message, "ExistingPlayer.Chatted") end)
        end
        if Players.LocalPlayer then
             warn("[SNIPER_LUA_CHAT_LISTEN] LocalPlayer found (" .. Players.LocalPlayer.Name .. "). Connecting Chatted event.")
             local existingConnection
             existingConnection = Players.LocalPlayer.Chatted:Connect(function(message)
                if not Players.LocalPlayer then
                    if existingConnection then existingConnection:Disconnect() end
                    return
                end
                handle_legacy_chat(Players.LocalPlayer, message, "LocalPlayer.Chatted")
             end)
        end
    end
end


local function connect_websocket()
    if connection_attempt_active then
        warn("[SNIPER_LUA_WS] Connection attempt already active. Skipping.")
        return
    end
    warn("[SNIPER_LUA_WS] Attempting to connect WebSocket...")
    connection_attempt_active = true
    is_connected = false
    if ws_client and ws_client.close then
        warn("[SNIPER_LUA_WS] Closing existing WebSocket client.")
        pcall(ws_client.close, ws_client)
    end
    ws_client = nil

    local function _handle_message_wrapper(message_data)
        local message_content = message_data
        if type(message_data) == "table" and message_data.data then
            message_content = message_data.data
        end
        if type(message_content) == "string" then
            handle_server_message(message_content)
        end
    end

    local function _handle_close_wrapper(code, reason)
        warn("[SNIPER_LUA_WS] WebSocket closed. Code: " .. tostring(code) .. ", Reason: " .. tostring(reason) .. ". Reconnecting in " .. RECONNECT_DELAY .. "s.")
        is_connected = false
        ws_client = nil
        connection_attempt_active = false
        task.wait(RECONNECT_DELAY)
        connect_websocket()
    end

    local function _handle_error_wrapper(err)
        warn("[SNIPER_LUA_WS] WebSocket error: " .. tostring(err) .. ". Reconnecting in " .. RECONNECT_DELAY .. "s.")
        if is_connected then
             pcall(function() if ws_client and ws_client.close then ws_client:close() end end)
        end
        is_connected = false
        ws_client = nil
        connection_attempt_active = false
        task.wait(RECONNECT_DELAY)
        connect_websocket()
    end

    local executor_ws_lib_name = "Unknown"

    if syn and syn.websocket and syn.websocket.connect then
        executor_ws_lib_name = "syn.websocket"
        warn("[SNIPER_LUA_WS] Using " .. executor_ws_lib_name)
        local connect_success, new_client = pcall(function()
            return syn.websocket.connect(WEBSOCKET_SERVER_URL)
        end)
        if not connect_success or not new_client then
            warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. ".connect failed: " .. tostring(new_client))
            connection_attempt_active = false
            task.wait(RECONNECT_DELAY)
            connect_websocket()
            return
        end
        ws_client = new_client
        ws_client.OnMessage:Connect(_handle_message_wrapper)
        ws_client.OnClose:Connect(_handle_close_wrapper)
        if ws_client.OnError then ws_client.OnError:Connect(_handle_error_wrapper)
        else warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. " has no OnError event.") end
        
        warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. " events connected.")
        connection_attempt_active = false
        send_identity_report()
        setup_chat_listeners()
    elseif WebSocket and WebSocket.connect then
        executor_ws_lib_name = "WebSocket (generic)"
        warn("[SNIPER_LUA_WS] Using " .. executor_ws_lib_name)
        local success_connect, client_or_error = pcall(WebSocket.connect, WEBSOCKET_SERVER_URL)
        if not success_connect or not client_or_error then
            warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. ".connect failed: " .. tostring(client_or_error))
            connection_attempt_active = false
            task.wait(RECONNECT_DELAY)
            connect_websocket()
            return
        end
        ws_client = client_or_error
        local message_event_config = {PascalEvent = "OnMessage", snake_event = "on_message", direct_on_event = "onmessage", direct_on_underscore_event = "on_message", emitter_event = "message"}
        local close_event_config = {PascalEvent = "OnClose", snake_event = "on_close", direct_on_event = "onclose", direct_on_underscore_event = "on_close", emitter_event = "close"}
        local error_event_config = {PascalEvent = "OnError", snake_event = "on_error", direct_on_event = "onerror", direct_on_underscore_event = "on_error", emitter_event = "error"}
        
        local attached_msg, msg_method = _try_attach_event(ws_client, message_event_config, _handle_message_wrapper)
        if not attached_msg then warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. ": Could not attach message handler.") else warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. " Msg handler: " .. msg_method) end
        
        local attached_close, close_method = _try_attach_event(ws_client, close_event_config, _handle_close_wrapper)
        if not attached_close then warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. ": Could not attach close handler.") else warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. " Close handler: " .. close_method) end
        
        local attached_error, error_method = _try_attach_event(ws_client, error_event_config, _handle_error_wrapper)
        if not attached_error then warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. ": Could not attach error handler.") else warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. " Error handler: " .. error_method) end
        
        warn("[SNIPER_LUA_WS] " .. executor_ws_lib_name .. " events attempted to connect.")
        connection_attempt_active = false
        if not (attached_msg and attached_close) then
             warn("[SNIPER_LUA_WS] Critical " .. executor_ws_lib_name .. " event handlers (message or close) not attached. Reconnecting.")
             if ws_client.close then pcall(ws_client.close, ws_client) end
             ws_client = nil; is_connected = false
             task.wait(RECONNECT_DELAY); connect_websocket()
             return
        end
        send_identity_report()
        setup_chat_listeners()
    else
        warn("[SNIPER_LUA_WS] No WebSocket library (syn or generic WebSocket) found. Cannot connect.")
        connection_attempt_active = false
        return
    end
end

warn("[SNIPER_LUA_CORE] Script initiated. Attempting initial WebSocket connection.")
connect_websocket()

spawn(function()
    while task.wait(PING_INTERVAL) do
        if ws_client and is_connected and tick() - last_ping_sent > PING_INTERVAL - 2 then
            send_ws_message({type = "ping_from_client"})
            last_ping_sent = tick()
        elseif not is_connected and not connection_attempt_active and (syn and syn.websocket or WebSocket) then 
             warn("[SNIPER_LUA_PING_LOOP] Not connected and no active attempt. Re-initiating connection.")
             connect_websocket()
        end
    end
end)

warn("[SNIPER_LUA_CORE] Script main execution finished. Background tasks (WS, ping) are running.")