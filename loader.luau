--[[
	██████╗ ██████╗  █████╗  ██████╗██╗     ███████╗
	██╔══██╗██╔══██╗██╔══██╗██╔════╝██║     ██╔════╝
	██████╔╝██████╔╝███████║██║     ██║     █████╗
	██╔══██╗██╔═══╝ ██╔══██║██║     ██║     ██╔══╝
	██║  ██║██║     ██║  ██║╚██████╗███████╗███████╗
	╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝╚══════╝╚══════╝  HUB

	UNIVERSAL LOADER — funciona en cualquier juego de Roblox
	=========================================================
	· Detecta el juego actual (placeId / gameId)
	· Descarga el manifiesto (index.json) desde GitHub raw
	· Carga automáticamente el script del juego si existe
	· Si no existe, abre un menú con todos los scripts disponibles
	· Los scripts de juego se gestionan con _HUB_SCRIPT_STOP

	Ejecutar:
	  loadstring(game:HttpGet("https://raw.githubusercontent.com/TU-USUARIO/oracle-hub/main/loader.luau"))()

	Config opcional antes de ejecutar:
	  getgenv().ORACLE_HUB_REPO = "https://raw.githubusercontent.com/otro/repo/main"
]]

local HUB_VERSION = "1.1.0"
local REPO = getgenv().ORACLE_HUB_REPO
	or "https://raw.githubusercontent.com/TU-USUARIO/oracle-hub/main"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LP = Players.LocalPlayer

-- ▸ teardown del script de juego anterior
if getgenv()._HUB_SCRIPT_STOP then
	pcall(getgenv()._HUB_SCRIPT_STOP)
	getgenv()._HUB_SCRIPT_STOP = nil
	task.wait(0.2)
end
if getgenv()._HUB_LOADER_STOP then
	pcall(getgenv()._HUB_LOADER_STOP)
	getgenv()._HUB_LOADER_STOP = nil
end

-- contexto compartido para los scripts de juego
getgenv()._HUB_CONTEXT = {
	placeId = game.PlaceId,
	gameId = game.GameId,
	jobId = game.JobId,
	hubVersion = HUB_VERSION,
	repo = REPO,
	player = LP and LP.Name or "?",
	loadedAt = os.time(),
}

-- ══════════════════════ utilidades ══════════════════════

local function hubLog(msg)
	print(("[OracleHub] %s"):format(tostring(msg)))
end

local function notify(title, text, dur)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = title, Text = text, Duration = dur or 5,
		})
	end)
end

local function fetch(path)
	-- desarrollo: getgenv().ORACLE_HUB_LOCAL_GAME = ruta local del script del juego
	if getgenv().ORACLE_HUB_LOCAL_GAME and path ~= "index.json" then
		hubLog("modo local: " .. tostring(getgenv().ORACLE_HUB_LOCAL_GAME))
		return readfile(tostring(getgenv().ORACLE_HUB_LOCAL_GAME))
	end
	local url = REPO .. "/" .. path .. "?t=" .. tostring(math.floor(tick() * 1000))
	local ok, res = pcall(function()
		return game:HttpGet(url, true)
	end)
	if not ok then
		return nil, res
	end
	return res
end

-- ══════════════════════ menú (GUI sin dependencias) ══════════════════════

local hubGui

local function destroyHubGui()
	if hubGui then
		pcall(function() hubGui:Destroy() end)
		hubGui = nil
	end
end

local function makeLabel(parent, props)
	local tl = Instance.new("TextLabel")
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.Gotham
	tl.TextColor3 = Color3.fromRGB(230, 230, 240)
	tl.TextSize = 14
	for k, v in pairs(props) do tl[k] = v end
	tl.Parent = parent
	return tl
end

local function buildMenu(index, currentGameName, reason)
	destroyHubGui()
	hubGui = Instance.new("ScreenGui")
	hubGui.Name = "OracleHubMenu"
	hubGui.ResetOnSpawn = false
	hubGui.DisplayOrder = 999

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(300, 380)
	frame.Position = UDim2.new(0.5, -150, 0.5, -190)
	frame.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Draggable = true
	frame.Parent = hubGui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

	makeLabel(frame, {
		Size = UDim2.new(1, -20, 0, 34), Position = UDim2.fromOffset(14, 8),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⚡ ORACLE HUB  v" .. HUB_VERSION,
		Font = Enum.Font.GothamBold, TextSize = 16,
	})

	makeLabel(frame, {
		Size = UDim2.new(1, -20, 0, 30), Position = UDim2.new(0, 14, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		TextSize = 12, TextColor3 = Color3.fromRGB(160, 165, 180),
		Text = reason or "",
	})

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, -16, 1, -92)
	scroll.Position = UDim2.new(0, 8, 0, 76)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 3
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = frame
	local layout = Instance.new("UIListLayout", scroll)
	layout.Padding = UDim.new(0, 6)

	local games = (index and index.games) or {}
	if #games == 0 then
		makeLabel(scroll, {
			Size = UDim2.new(1, -8, 0, 40), LayoutOrder = 1,
			TextWrapped = true, TextColor3 = Color3.fromRGB(200, 120, 120),
			Text = "Manifiesto vacío o ilegible — revisa index.json en el repo",
		})
	end

	for i, entry in ipairs(games) do
		local isCurrent = entry.id == tostring(game.PlaceId)
			or (entry.gameId and entry.gameId == tostring(game.GameId))
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -8, 0, 52)
		btn.LayoutOrder = i + 1
		btn.BackgroundColor3 = isCurrent
			and Color3.fromRGB(28, 60, 40) or Color3.fromRGB(26, 27, 34)
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = true
		btn.Parent = scroll
		Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

		makeLabel(btn, {
			Size = UDim2.new(1, -16, 0, 22), Position = UDim2.fromOffset(10, 6),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.GothamBold,
			Text = (isCurrent and "▶ " or "") .. tostring(entry.name or entry.id),
		})
		makeLabel(btn, {
			Size = UDim2.new(1, -16, 0, 18), Position = UDim2.new(0, 10, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 11, TextColor3 = Color3.fromRGB(150, 155, 170),
			Text = tostring(entry.description or entry.script or ""),
		})

		btn.MouseButton1Click:Connect(function()
			notify("Oracle Hub", "Cargando " .. tostring(entry.name or entry.script) .. "…", 3)
			hubLog("cargando " .. tostring(entry.script))
			local src, err = fetch(tostring(entry.script))
			if not src then
				notify("Oracle Hub", "Error HTTP: " .. tostring(err), 6)
				hubLog("ERROR fetch: " .. tostring(err))
				return
			end
			local fn, lerr = loadstring(src)
			if not fn then
				notify("Oracle Hub", "Error de sintaxis: " .. tostring(lerr), 6)
				hubLog("ERROR loadstring: " .. tostring(lerr))
				return
			end
			destroyHubGui()
			local okR, rerr = pcall(fn)
			if not okR then
				hubLog("ERROR runtime: " .. tostring(rerr))
				notify("Oracle Hub", "Error al ejecutar: " .. tostring(rerr), 6)
			end
		end)
	end

	local foot = makeLabel(frame, {
		Size = UDim2.new(1, -20, 0, 16), Position = UDim2.new(0, 14, 1, -20),
		TextXAlignment = Enum.TextXAlignment.Left, TextSize = 10,
		TextColor3 = Color3.fromRGB(110, 115, 130),
		Text = ("juego: %s · %d scripts en el hub"):format(currentGameName or "?", #games),
	})
	foot.Parent = frame
end

-- ══════════════════════ arranque ══════════════════════

local function main()
	local gameName = "?"
	pcall(function()
		local info = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		gameName = info.Name or "?"
	end)
	getgenv()._HUB_CONTEXT.gameName = gameName
	hubLog(("v%s · juego: %s (place %d, universe %d)")
		:format(HUB_VERSION, gameName, game.PlaceId, game.GameId))

	local raw, err
	if getgenv().ORACLE_HUB_INDEX_OVERRIDE then
		hubLog("usando manifiesto override (dev)")
		raw = HttpService:JSONEncode(getgenv().ORACLE_HUB_INDEX_OVERRIDE)
	else
		raw, err = fetch("index.json")
	end
	if not raw then
		notify("Oracle Hub", "No pude bajar index.json — revisa el repo", 6)
		hubLog("ERROR index: " .. tostring(err))
		buildMenu(nil, gameName, "Sin conexión con el repo (" .. REPO .. ")")
		return
	end

	local index = {}
	local okJ, jerr = pcall(function()
		index = HttpService:JSONDecode(raw)
	end)
	if not okJ then
		notify("Oracle Hub", "index.json inválido", 6)
		hubLog("ERROR json: " .. tostring(jerr))
		buildMenu(nil, gameName, "index.json no parsea")
		return
	end

	hubLog(("manifiesto v%s · %d juegos en el hub")
		:format(tostring(index.version or "?"), #(index.games or {})))

	-- ¿hay script para ESTE juego?
	local match
	for _, entry in ipairs(index.games or {}) do
		if entry.id == tostring(game.PlaceId)
			or (entry.gameId and tostring(entry.gameId) == tostring(game.GameId)) then
			match = entry
			break
		end
	end

	if match then
		local scriptName = tostring(match.name or match.id)
		hubLog("script del juego encontrado: " .. tostring(match.script))
		notify("Oracle Hub", "Cargando " .. scriptName .. "…", 3)
		local src, ferr = fetch(tostring(match.script))
		if not src then
			notify("Oracle Hub", "Error HTTP en el script: " .. tostring(ferr), 6)
			buildMenu(index, gameName, "Falló la descarga del script del juego")
			return
		end
		local fn, lerr = loadstring(src)
		if not fn then
			notify("Oracle Hub", "Sintaxis inválida en " .. tostring(match.script), 6)
			buildMenu(index, gameName, tostring(lerr))
			return
		end
		local okR, rerr = pcall(fn)
		if not okR then
			hubLog("ERROR runtime: " .. tostring(rerr))
			notify("Oracle Hub", "Error al ejecutar: " .. tostring(rerr), 6)
			buildMenu(index, gameName, "El script falló al ejecutar")
		end
	else
		hubLog("sin script para este juego — abriendo menú")
		notify("Oracle Hub", "Sin script para este juego — menú abierto", 4)
		buildMenu(index, gameName, "Aún no hay script para " .. (gameName or "este juego") .. " — puedes ejecutar cualquier otro:")
	end
end

-- reejecución segura + registro de teardown
local okMain, errMain = pcall(main)
if not okMain then
	hubLog("FATAL: " .. tostring(errMain))
	notify("Oracle Hub", "FATAL: " .. tostring(errMain), 8)
end

getgenv()._HUB_LOADER_STOP = function()
	destroyHubGui()
	hubLog("loader descargado")
end
