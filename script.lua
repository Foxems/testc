local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local WEBSOCKET_SERVER_URL = "ws://192.168.1.105:8080" -- MAKE SURE THIS IS YOUR CORRECT HOST LAN IP

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
        return
    end

    if data.type == "connected" then
        instanceIdFromServer = data.instanceId
        is_connected = true -- Set connected true when server confirms
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

        ws_client.OnMessage:Connect(function(message)
            handle_server_message(message)
        end)

        ws_client.OnClose:Connect(function(code, reason)
            is_connected = false
            ws_client = nil 
            connection_attempt_active = false
            task.wait(RECONNECT_DELAY)
            connect_websocket()
        end)
        
        is_connected = true -- For syn, connection is often implied if connect() succeeds
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
        connection_attempt_active = false -- If WebSocket.connect returned a client, this attempt is done.
                                          -- is_connected will be set true by the server's "connected" message.

        -- The problematic ws_client.on_open:connect(...) block is removed.

        -- We assume on_message, on_close, on_error might still work with :connect for this executor.
        -- If these also cause errors, their connection method needs to be investigated/changed too.
        if ws_client.on_message and type(ws_client.on_message.connect) == "function" then
            ws_client.on_message:connect(function(message)
                handle_server_message(message)
            end)
        elseif ws_client.on and type(ws_client.on) == "function" then -- Try common alternative
            ws_client:on("message", function(message) handle_server_message(message) end)
        else
            warn("WebSocket: Could not attach message handler.")
        end

        if ws_client.on_close and type(ws_client.on_close.connect) == "function" then
            ws_client.on_close:connect(function(code, reason)
                is_connected = false
                ws_client = nil
                -- connection_attempt_active will be reset by the next call to connect_websocket
                task.wait(RECONNECT_DELAY)
                connect_websocket()
            end)
        elseif ws_client.on and type(ws_client.on) == "function" then -- Try common alternative
            ws_client:on("close", function(code, reason) 
                is_connected = false; ws_client = nil; task.wait(RECONNECT_DELAY); connect_websocket() 
            end)
        else
            warn("WebSocket: Could not attach close handler.")
        end
        
        if ws_client.on_error and type(ws_client.on_error.connect) == "function" then
            ws_client.on_error:connect(function(err)
                if is_connected then -- only try to close if it thought it was connected
                     pcall(function() if ws_client and ws_client.close then ws_client:close() end end)
                end
                is_connected = false
                ws_client = nil
                task.wait(RECONNECT_DELAY)
                connect_websocket()
            end)
        elseif ws_client.on and type(ws_client.on) == "function" then -- Try common alternative
             ws_client:on("error", function(err)
                if is_connected then pcall(function() if ws_client and ws_client.close then ws_client:close() end end) end
                is_connected = false; ws_client = nil; task.wait(RECONNECT_DELAY); connect_websocket()
            end)
        else
             warn("WebSocket: Could not attach error handler.")
        end
    else
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