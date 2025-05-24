local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local WEBSOCKET_SERVER_URL = "ws://192.168.0.225:8080" 
local RECONNECT_DELAY = 7
local PING_INTERVAL = 25

local ws_client
local instanceIdFromServer = nil 
local is_connected = false
local last_ping_sent = 0
local connection_attempt_active = false

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
        if not (data_table.type == "identity_report" and ws_client) then return end
    end
    
    local success_json, json_data = pcall(HttpService.JSONEncode, HttpService, data_table)
    if not success_json or not ws_client then
        if not success_json then warn("JSONEncode failed: " .. tostring(json_data)) end
        return
    end

    local sent, method_or_error = _try_send_message(ws_client, json_data)
    if not sent then
        warn("All WebSocket send methods failed. Last error: " .. tostring(method_or_error))
    end
end

local function send_identity_report()
    if not Players.LocalPlayer then
        warn("LocalPlayer not available for identity report.")
        task.wait(1) 
        if not Players.LocalPlayer then return end 
    end
    local userId = Players.LocalPlayer.UserId
    local userName = Players.LocalPlayer.Name
    if userId and userName then
        send_ws_message({
            type = "identity_report",
            userId = tostring(userId),
            userName = userName
        })
    else
        warn("Could not send identity report: UserId or UserName missing.")
    end
end

local function handle_server_message(message_string)
    local success, data = pcall(HttpService.JSONDecode, HttpService, message_string)

    if not success then
        warn("Failed to decode JSON message: " .. message_string .. " Error: " .. tostring(data))
        return
    end

    if data.type == "connected" then
        instanceIdFromServer = data.instanceId 
        is_connected = true
        
        local current_server_status = data.status
        
        if current_server_status == "active_cooldown" and data.cooldownUntil then
            -- Cooldown is handled server-side, client just acknowledges.
        elseif current_server_status == 'idle' then
            send_ws_message({ type = "status_update", status = "idle" })
        elseif current_server_status == 'joining_pending_confirmation' then
            -- Server is waiting for us to confirm the join after teleporting.
            -- The Luau script will send 'joined_game_confirmed' or 'teleport_failed' after the attempt.
        else
            if not current_server_status then 
                send_ws_message({ type = "status_update", status = "idle" })
            end
        end

    elseif data.type == "teleport" then
        local placeId = tonumber(data.placeId)
        local jobId = tostring(data.jobId)
        if placeId and jobId and Players.LocalPlayer then
            send_ws_message({ type = "status_update", status = "joining_game", placeId = placeId, jobId = jobId })
            
            local tp_success, tp_error = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, placeId, jobId, Players.LocalPlayer)
            
            task.wait(5) -- Wait regardless of immediate pcall success to allow game to load

            if tp_success then
                send_ws_message({ type = "status_update", status = "joined_game_confirmed", placeId = placeId, jobId = jobId })
            else
                send_ws_message({ type = "status_update", status = "teleport_failed", placeId = placeId, jobId = jobId, error = tostring(tp_error) })
            end
        end
    elseif data.type == "ping" then
        send_ws_message({ type = "pong" })
    elseif data.type == "error" and data.message == "Identity not established." then
        send_identity_report()
    end
end

local function connect_websocket()
    if connection_attempt_active then
        return
    end
    connection_attempt_active = true
    is_connected = false 
    if ws_client and ws_client.close then
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
        is_connected = false
        ws_client = nil
        connection_attempt_active = false
        task.wait(RECONNECT_DELAY)
        connect_websocket()
    end

    local function _handle_error_wrapper(err)
        if is_connected then 
             pcall(function() if ws_client and ws_client.close then ws_client:close() end end)
        end
        is_connected = false
        ws_client = nil
        connection_attempt_active = false
        task.wait(RECONNECT_DELAY)
        connect_websocket()
    end


    if syn and syn.websocket and syn.websocket.connect then 
        local connect_success, new_client = pcall(function()
            return syn.websocket.connect(WEBSOCKET_SERVER_URL)
        end)

        if not connect_success or not new_client then
            warn("syn.websocket.connect failed: " .. tostring(new_client))
            connection_attempt_active = false
            task.wait(RECONNECT_DELAY)
            connect_websocket() 
            return
        end
        ws_client = new_client

        ws_client.OnMessage:Connect(_handle_message_wrapper)
        ws_client.OnClose:Connect(_handle_close_wrapper)
        if ws_client.OnError then ws_client.OnError:Connect(_handle_error_wrapper) end
        
        connection_attempt_active = false
        send_identity_report() 
        
    elseif WebSocket and WebSocket.connect then 
        local success_connect, client_or_error = pcall(WebSocket.connect, WEBSOCKET_SERVER_URL)

        if not success_connect or not client_or_error then
            warn("WebSocket.connect failed: " .. tostring(client_or_error))
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
        if not attached_msg then warn("WebSocket: Could not attach message handler.") end
        
        local attached_close, close_method = _try_attach_event(ws_client, close_event_config, _handle_close_wrapper)
        if not attached_close then warn("WebSocket: Could not attach close handler.") end

        local attached_error, error_method = _try_attach_event(ws_client, error_event_config, _handle_error_wrapper)
        if not attached_error then warn("WebSocket: Could not attach error handler.") end
        
        connection_attempt_active = false 
        if not (attached_msg and attached_close) then
             warn("Critical WebSocket event handlers not attached. Reconnecting.")
             if ws_client.close then pcall(ws_client.close, ws_client) end
             ws_client = nil; is_connected = false 
             task.wait(RECONNECT_DELAY); connect_websocket()
             return
        end
        send_identity_report()
        
    else
        warn("No WebSocket library found.")
        connection_attempt_active = false
        task.wait(RECONNECT_DELAY) 
        connect_websocket()
        return 
    end
end

connect_websocket()

spawn(function()
    while task.wait(PING_INTERVAL) do
        if ws_client and is_connected and tick() - last_ping_sent > PING_INTERVAL - 2 then
            send_ws_message({type = "ping_from_client"})
            last_ping_sent = tick()
        elseif not is_connected and not connection_attempt_active then 
             connect_websocket()
        end
    end
end)