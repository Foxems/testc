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

local function send_ws_message(data_table)
    if not (ws_client and is_connected) then
        return
    end
    
    local success, json_data = pcall(HttpService.JSONEncode, HttpService, data_table)
    if success and ws_client then
        if ws_client.send then
            pcall(ws_client.send, ws_client, json_data)
        end
    end
end

local function handle_server_message(message_string)
    local success, data = pcall(HttpService.JSONDecode, HttpService, message_string)

    if not success then
        warn("Failed to decode JSON message: " .. message_string)
        return
    end

    if data.type == "connected" then
        instanceIdFromServer = data.instanceId
        is_connected = true 
        send_ws_message({ type = "status_update", status = "idle" })
    elseif data.type == "teleport" then
        local placeId = tonumber(data.placeId)
        local jobId = tostring(data.jobId)
        if placeId and jobId and Players.LocalPlayer then
            send_ws_message({ type = "status_update", status = "joining_game", placeId = placeId, jobId = jobId })
            
            local tp_success, tp_error = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, placeId, jobId, Players.LocalPlayer)
            if tp_success then
                task.wait(5) 
                send_ws_message({ type = "status_update", status = "joined_game_confirmed", placeId = placeId, jobId = jobId })
            else
                send_ws_message({ type = "status_update", status = "teleport_failed", placeId = placeId, jobId = jobId, error = tostring(tp_error) })
            end
        end
    elseif data.type == "ping" then
        send_ws_message({ type = "pong" })
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
        task.wait(RECONNECT_DELAY)
        connect_websocket()
    end

    local function _handle_error_wrapper(err)
        if is_connected then 
             pcall(function() if ws_client and ws_client.close then ws_client:close() end end)
        end
        is_connected = false
        ws_client = nil
        task.wait(RECONNECT_DELAY)
        connect_websocket()
    end


    if syn and syn.websocket and syn.websocket.connect then 
        local connect_success, new_client = pcall(function()
            return syn.websocket.connect(WEBSOCKET_SERVER_URL)
        end)

        if not connect_success or not new_client then
            connection_attempt_active = false
            task.wait(RECONNECT_DELAY)
            connect_websocket() 
            return
        end
        ws_client = new_client

        ws_client.OnMessage:Connect(_handle_message_wrapper)
        ws_client.OnClose:Connect(_handle_close_wrapper)
        
        connection_attempt_active = false
        
    elseif WebSocket and WebSocket.connect then 
        local success_connect, client_or_error = pcall(WebSocket.connect, WEBSOCKET_SERVER_URL)

        if not success_connect or not client_or_error then
            connection_attempt_active = false
            task.wait(RECONNECT_DELAY)
            connect_websocket()
            return
        end
        ws_client = client_or_error
        connection_attempt_active = false

        local message_handler_attached = false
        if not message_handler_attached and ws_client.OnMessage and type(ws_client.OnMessage.Connect) == "function" then
            local s,e = pcall(function() ws_client.OnMessage:Connect(_handle_message_wrapper) end)
            if s then message_handler_attached = true else warn("ws_client.OnMessage:Connect failed: " .. tostring(e)) end
        end
        if not message_handler_attached and ws_client.on_message and type(ws_client.on_message.connect) == "function" then
            local s,e = pcall(function() ws_client.on_message:connect(_handle_message_wrapper) end)
            if s then message_handler_attached = true else warn("ws_client.on_message:connect failed: " .. tostring(e)) end
        end
        if not message_handler_attached and ws_client.on and type(ws_client.on) == "function" then 
            local s,e = pcall(function() ws_client:on("message", _handle_message_wrapper) end)
            if s then message_handler_attached = true else warn("ws_client:on('message', ...) failed: " .. tostring(e)) end
        end
        if not message_handler_attached then 
            local s,e = pcall(function() ws_client.onmessage = _handle_message_wrapper end)
            if s and type(ws_client.onmessage) == "function" then message_handler_attached = true else if not s then warn("Assigning ws_client.onmessage failed: " .. tostring(e)) end end
        end
        if not message_handler_attached then
            local s,e = pcall(function() ws_client.on_message = _handle_message_wrapper end)
            if s and type(ws_client.on_message) == "function" then message_handler_attached = true else if not s then warn("Assigning ws_client.on_message failed: " .. tostring(e)) end end
        end
        if not message_handler_attached then warn("WebSocket: Could not attach any message handler.") end

        local close_handler_attached = false
        if not close_handler_attached and ws_client.OnClose and type(ws_client.OnClose.Connect) == "function" then
            local s,e = pcall(function() ws_client.OnClose:Connect(_handle_close_wrapper) end)
            if s then close_handler_attached = true else warn("ws_client.OnClose:Connect failed: " .. tostring(e)) end
        end
        if not close_handler_attached and ws_client.on_close and type(ws_client.on_close.connect) == "function" then
            local s,e = pcall(function() ws_client.on_close:connect(_handle_close_wrapper) end)
            if s then close_handler_attached = true else warn("ws_client.on_close:connect failed: " .. tostring(e)) end
        end
        if not close_handler_attached and ws_client.on and type(ws_client.on) == "function" then
            local s,e = pcall(function() ws_client:on("close", _handle_close_wrapper) end)
            if s then close_handler_attached = true else warn("ws_client:on('close', ...) failed: " .. tostring(e)) end
        end
        if not close_handler_attached then
            local s,e = pcall(function() ws_client.onclose = _handle_close_wrapper end)
            if s and type(ws_client.onclose) == "function" then close_handler_attached = true else if not s then warn("Assigning ws_client.onclose failed: " .. tostring(e)) end end
        end
        if not close_handler_attached then
            local s,e = pcall(function() ws_client.on_close = _handle_close_wrapper end)
            if s and type(ws_client.on_close) == "function" then close_handler_attached = true else if not s then warn("Assigning ws_client.on_close failed: " .. tostring(e)) end end
        end
        if not close_handler_attached then warn("WebSocket: Could not attach any close handler.") end
        
        local error_handler_attached = false
        if not error_handler_attached and ws_client.OnError and type(ws_client.OnError.Connect) == "function" then
             local s,e = pcall(function() ws_client.OnError:Connect(_handle_error_wrapper) end)
             if s then error_handler_attached = true else warn("ws_client.OnError:Connect failed: " .. tostring(e)) end
        end
        if not error_handler_attached and ws_client.on_error and type(ws_client.on_error.connect) == "function" then
             local s,e = pcall(function() ws_client.on_error:connect(_handle_error_wrapper) end)
             if s then error_handler_attached = true else warn("ws_client.on_error:connect failed: " .. tostring(e)) end
        end
        if not error_handler_attached and ws_client.on and type(ws_client.on) == "function" then
             local s,e = pcall(function() ws_client:on("error", _handle_error_wrapper) end)
             if s then error_handler_attached = true else warn("ws_client:on('error', ...) failed: " .. tostring(e)) end
        end
        if not error_handler_attached then
            local s,e = pcall(function() ws_client.onerror = _handle_error_wrapper end)
            if s and type(ws_client.onerror) == "function" then error_handler_attached = true else if not s then warn("Assigning ws_client.onerror failed: " .. tostring(e)) end end
        end
        if not error_handler_attached then
            local s,e = pcall(function() ws_client.on_error = _handle_error_wrapper end)
            if s and type(ws_client.on_error) == "function" then error_handler_attached = true else if not s then warn("Assigning ws_client.on_error failed: " .. tostring(e)) end end
        end
        if not error_handler_attached then warn("WebSocket: Could not attach any error handler.") end
        
    else
        connection_attempt_active = false
        warn("No WebSocket library (syn.websocket or WebSocket) found.")
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