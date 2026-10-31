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

local HUB_VERSION = "1.2.0"
local REPO = getgenv().ORACLE_HUB_REPO
	or "https://raw.githubusercontent.com/yadieldanger/oracle-hub/main"
local API_REPO = getgenv().ORACLE_HUB_API_REPO or "yadieldanger/oracle-hub"
local API_REF = getgenv().ORACLE_HUB_REF or "main"

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

-- token de acceso al repo (privado): getgenv().ORACLE_HUB_PAT o hub_pat.json
local patLoaded = nil
local function savePat(pat)
	patLoaded = tostring(pat)
	pcall(function()
		writefile("hub_pat.json", HttpService:JSONEncode({
			pat = patLoaded,
			note = "token de acceso al hub - no compartir",
			savedAt = os.time(),
		}))
	end)
end

local function loadPat()
	if patLoaded ~= nil then return patLoaded end
	patLoaded = false
	if getgenv().ORACLE_HUB_PAT then
		patLoaded = tostring(getgenv().ORACLE_HUB_PAT)
	else
		pcall(function()
			patLoaded = tostring(HttpService:JSONDecode(readfile("hub_pat.json")).pat)
		end)
	end
	if patLoaded then
		hubLog("token de repo privado cargado")
	end
	return patLoaded
end

-- caja de activación para clientes: pegan su token una vez
local function askForToken()
	local ok, result = pcall(function()
		local sg = Instance.new("ScreenGui")
		sg.Name = "OracleHubActivate"
		sg.ResetOnSpawn = false
		sg.DisplayOrder = 1000
		sg.Parent = game:GetService("CoreGui")

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(340, 170)
		frame.Position = UDim2.new(0.5, -170, 0.5, -85)
		frame.BackgroundColor3 = Color3.fromRGB(16, 17, 22)
		frame.BorderSizePixel = 0
		frame.Active = true
		frame.Draggable = true
		frame.Parent = sg
		Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

		local function label(props)
			local tl = Instance.new("TextLabel")
			tl.BackgroundTransparency = 1
			tl.Font = Enum.Font.Gotham
			tl.TextColor3 = Color3.fromRGB(230, 230, 240)
			tl.TextSize = 13
			for k, v in pairs(props) do tl[k] = v end
			tl.Parent = frame
			return tl
		end

		label({
			Size = UDim2.new(1, -24, 0, 30), Position = UDim2.fromOffset(16, 10),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.GothamBold, TextSize = 16,
			Text = "⚡ ORACLE HUB — Activación",
		})
		label({
			Size = UDim2.new(1, -24, 0, 40), Position = UDim2.new(0, 16, 0, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true, TextSize = 11,
			TextColor3 = Color3.fromRGB(160, 165, 180),
			Text = "Pega tu token de acceso (te lo entrega el vendedor tras la compra).",
		})

		local box = Instance.new("TextBox")
		box.Size = UDim2.new(1, -32, 0, 34)
		box.Position = UDim2.new(0, 16, 0, 84)
		box.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
		box.BorderSizePixel = 0
		box.Font = Enum.Font.Code
		box.TextSize = 12
		box.TextColor3 = Color3.fromRGB(235, 235, 245)
		box.PlaceholderText = "github_pat_… o ghp_…"
		box.Text = ""
		box.ClearTextOnFocus = false
		box.Parent = frame
		Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)

		local state = { done = false, pat = nil }
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -32, 0, 30)
		btn.Position = UDim2.new(0, 16, 0, 126)
		btn.BackgroundColor3 = Color3.fromRGB(34, 92, 60)
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 13
		btn.TextColor3 = Color3.fromRGB(235, 255, 240)
		btn.Text = "ACTIVAR"
		btn.Parent = frame
		Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

		btn.MouseButton1Click:Connect(function()
			local txt = string.gsub(box.Text or "", "%s", "")
			if #txt < 10 then return end
			state.done = true
			state.pat = txt
		end)

		local t0 = os.clock()
		while not state.done and os.clock() - t0 < 120 do
			task.wait(0.2)
		end
		pcall(function() sg:Destroy() end)
		return state.done and state.pat or nil
	end)
	return ok and result or nil
end

local function fetch(path)
	-- desarrollo: getgenv().ORACLE_HUB_LOCAL_GAME = ruta local del script del juego
	if getgenv().ORACLE_HUB_LOCAL_GAME and path ~= "index.json" then
		hubLog("modo local: " .. tostring(getgenv().ORACLE_HUB_LOCAL_GAME))
		return readfile(tostring(getgenv().ORACLE_HUB_LOCAL_GAME))
	end

	-- repo PRIVADO: contents API con token (raw directo vía Accept header)
	local pat = loadPat()
	if pat then
		local ok, res = pcall(function()
			return request({
				Url = ("https://api.github.com/repos/%s/contents/%s?ref=%s")
					:format(API_REPO, path, API_REF),
				Headers = {
					Authorization = "Bearer " .. pat,
					Accept = "application/vnd.github.raw",
					["X-GitHub-Api-Version"] = "2022-11-28",
				},
			})
		end)
		if not ok then
			return nil, res
		end
		if type(res) == "table" then
			if res.StatusCode == 200 and res.Body then
				return res.Body
			end
			return nil, ("HTTP %s"):format(tostring(res.StatusCode))
		end
		return nil, tostring(res)
	end

	-- repo PÚBLICO: raw clásico
	local url = REPO .. "/" .. path .. "?t=" .. tostring(math.floor(tick() * 1000))
	local ok, res = pcall(function()
		return game:HttpGet(url, true)
	end)
	if ok then
		return res
	end

	-- falló: solo ofrecer activación si el archivo no existe (404 = repo privado)
	local errTxt = tostring(res)
	if not getgenv()._HUB_ASKED and (errTxt:find("404") or errTxt:lower():find("not found")) then
		getgenv()._HUB_ASKED = true
		hubLog("sin acceso — solicitando token de activación…")
		notify("Oracle Hub", "Se requiere activación — pega tu token", 5)
		local newPat = askForToken()
		if newPat then
			savePat(newPat)
			notify("Oracle Hub", "Token guardado — reintentando…", 4)
			patLoaded = nil
			return fetch(path)
		end
	end
	return nil, res
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
