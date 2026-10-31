--[[
	ORACLE TRADER v2 — Roblox Stock Exchange 2
	===========================================
	El motor de precios del juego es determinista y corre client-side
	(PriceEngine con hash por seed de jugador). Este script lee el
	FUTURO y ejecuta la mejor decisión disponible en cada momento.

	v2:
	- HOT HUNTER: calendario de ventanas "hot ticker" futuras (los
	  eventos que mueven +100..600%) — prioriza el asset hot, entra al
	  inicio de la ventana, sale antes del fin, trailing más fino.
	- RÉGIMEN: marketCycle(t) futuro ajusta sesgo long/short y tamaño.
	- CALIDAD DE RUTA: descarta trips cuyo dibujo interno superaría el
	  stop-loss; score = retorno penalizado por drawdown.
	- MOTOR DE RIESGO: límite de pérdida diaria, kill-switch tras N
	  stops seguidos, tamaño proporcional a la confianza.
	- ENTRADAS ESCALONADAS: divide la orden en tramos cerca del valle.
	- LIBRO COMPLETO: VWAP caminando el libro futuro (no solo el touch).
	- STATS + PERSISTENCIA: PnL, win rate, historial en disco.
]]

-- ▸ teardown de una corrida anterior
if getgenv()._ORACLE_STOP then
	pcall(getgenv()._ORACLE_STOP)
	getgenv()._ORACLE_STOP = nil
	task.wait(0.2)
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer

local State = require(LP.PlayerScripts.Client.State)
local PriceEngine = require(game:GetService("ReplicatedStorage").Shared.PriceEngine)
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local CFG = {
	auto         = false,   -- siempre OFF al cargar (seguridad)
	allowShorts  = false,
	sizingPct    = 25,      -- % del netWorth base por posición
	leverage     = 1,
	minRet       = 1.5,     -- % mínimo del round-trip neto
	horizonMin   = 480,     -- minutos de horizonte del oráculo
	maxPositions = 2,
	stopLoss     = 4,       -- % contra la entrada
	trail        = 8,       -- % trailing stop desde el máximo
	trailHot     = 5,       -- trailing más fino durante ventana hot
	maxHoldMin   = 180,
	entryLead    = 45,      -- s: abre cuando el entry está a <= N seg
	replanSecs   = 30,
	tranches     = 2,       -- tramos por entrada (1 = todo de golpe)
	dailyLossPct = 15,      -- pérdida diaria máx (% del NW inicial)
	killStreak   = 3,       -- stops seguidos antes del kill-switch
	hotHunter    = true,    -- calendario hot ticker activo
	regimeAware  = true,    -- sesgo por régimen de mercado
	useLimits    = true,    -- órdenes límite en el valle predicho
	fedGuard     = true,    -- no abrir cerca de la Fed
	sectorDiversity = true, -- no duplicar sector
	takePartial  = true,    -- cierra 50% al 60% del objetivo
	reservePct   = 10,      -- % de NW que nunca se opera
	hotLegs      = true,    -- multi-piernas dentro de ventanas hot
	autoLev      = true,    -- palanca extra solo para trips élite
	maxAutoLev   = 2,       -- techo del auto-apalancamiento
	atrStopMult  = 2.5,     -- stop = max(fijo, ATR×este factor)
	testPct      = 2,
}

local RT_COST = 0.006 -- 0.6% ida y vuelta (spread real + fee)

local running = true
local connections = {}
local UI = {
	console = nil, overlayText = nil, window = nil,
	_statusStr = nil, _statsStr = nil, _topStr = nil, _logQ = {},
	_autoOff = false,
	stNW = nil, stPnl = nil, stWR = nil, stN = nil,
}

local function conn(sig, fn)
	local c = sig:Connect(fn)
	table.insert(connections, c)
	return c
end

-- Los loops NUNCA tocan Instances (el executor lo bloquea desde hilos
-- spawnados). log() y los updaters dejan datos en UI._* y el flusher de
-- Heartbeat — con privilegios de GUI — los pinta.
local function log(msg)
	print("[Oracle] " .. msg)
	table.insert(UI._logQ, os.date("%H:%M:%S") .. "  " .. tostring(msg))
	if #UI._logQ > 80 then
		table.remove(UI._logQ, 1)
	end
end

-- toast por el sistema del PROPIO juego (su hilo siempre tiene permisos)
local function gameToast(text, color)
	pcall(function()
		State.signals.notify:Fire({ text = text, color = color or "brand" })
	end)
end

local function money(v)
	local sign = v < 0 and "-" or ""
	v = math.abs(v)
	local s = string.format("%.0f", v)
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return sign .. "$" .. s .. out
end

-- ══════════════════════════════ STATS ══════════════════════════════

local STAT_FILE = "oracle_stats.json"
local stats = { pnl = 0, wins = 0, losses = 0, stops = 0, trades = {}, equity = {}, bestWin = 0, worstLoss = 0 }
local startNW = nil

do
	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(STAT_FILE))
	end)
	if ok and type(data) == "table" then
		stats.pnl = tonumber(data.pnl) or 0
		stats.wins = tonumber(data.wins) or 0
		stats.losses = tonumber(data.losses) or 0
		stats.stops = 0
		stats.trades = type(data.trades) == "table" and data.trades or {}
		stats.equity = type(data.equity) == "table" and data.equity or {}
		stats.bestWin = tonumber(data.bestWin) or 0
		stats.worstLoss = tonumber(data.worstLoss) or 0
	end
end

local function persistStats()
	pcall(function()
		local trimmed = {}
		for i = math.max(1, #stats.trades - 49), #stats.trades do
			trimmed[#trimmed+1] = stats.trades[i]
		end
		writefile(STAT_FILE, HttpService:JSONEncode({
			pnl = stats.pnl, wins = stats.wins, losses = stats.losses,
			trades = trimmed, equity = stats.equity,
			bestWin = stats.bestWin, worstLoss = stats.worstLoss,
		}))
	end)
end

-- resumen de los últimos 50 trades
local function tradeSummary()
	local gw, gl = 0, 0
	for _, tr in ipairs(stats.trades) do
		if tr.pnl >= 0 then gw = gw + tr.pnl else gl = gl - tr.pnl end
	end
	local pf = gl > 0 and gw / gl or (gw > 0 and 99 or 0)
	return gw, gl, pf
end

-- sparkline ASCII de la curva de equity
local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local function sparkline(equity, width)
	if #equity < 2 then return "(curva en construcción…)" end
	local vals = {}
	for i = math.max(1, #equity - width + 1), #equity do
		vals[#vals+1] = equity[i].nw
	end
	local lo, hi = math.huge, -math.huge
	for _, v in ipairs(vals) do
		if v < lo then lo = v end
		if v > hi then hi = v end
	end
	if hi - lo < 1e-9 then return string.rep("▄", #vals) end
	local out = {}
	for _, v in ipairs(vals) do
		local idx = math.clamp(math.floor((v - lo) / (hi - lo) * 7) + 1, 1, 8)
		out[#out+1] = BLOCKS[idx]
	end
	return table.concat(out)
end

local function recordClose(id, pnl, reason)
	pnl = tonumber(pnl) or 0
	stats.pnl = stats.pnl + pnl
	if pnl >= 0 then
		stats.wins = stats.wins + 1
		stats.stops = 0
	else
		stats.losses = stats.losses + 1
		if reason == "stop" or reason == "stop-loss" then
			stats.stops = stats.stops + 1
		end
	end
	table.insert(stats.trades, {
		t = os.date("%m-%d %H:%M"), id = id,
		pnl = math.floor(pnl * 100) / 100, r = reason or "",
	})
	while #stats.trades > 50 do table.remove(stats.trades, 1) end
	if pnl > stats.bestWin then stats.bestWin = pnl end
	if pnl < stats.worstLoss then stats.worstLoss = pnl end
	UI._statsDirty = true
	persistStats()

	-- límite diario
	if startNW and stats.pnl <= -(startNW * CFG.dailyLossPct / 100) then
		if CFG.auto then
			CFG.auto = false
			UI._autoOff = true
			log(("🛑 LÍMITE DIARIO: pnl sesión %s <= -%d%% de %s — AUTO apagado")
				:format(money(stats.pnl), CFG.dailyLossPct, money(startNW)))
			gameToast("🛑 Oracle: límite diario alcanzado — AUTO apagado", "red")
		end
	end
	-- kill switch
	if stats.stops >= CFG.killStreak then
		if CFG.auto then
			CFG.auto = false
			UI._autoOff = true
			log(("🛑 KILL-SWITCH: %d stops seguidos — AUTO apagado"):format(stats.stops))
			gameToast("🛑 Oracle: kill-switch por stops seguidos — AUTO apagado", "red")
		end
	end
end

-- ══════════════════════════════ HOT HUNTER ═════════════════════════

local hotCal = { windows = {}, stamp = 0 }

local function hotAt(t)
	for _, w in ipairs(hotCal.windows) do
		if t >= w.start and t <= w.endsAt then return w end
	end
	return nil
end

local function rebuildHotCal()
	local ok, err = pcall(function()
		local now = State.now()
		local wins = {}
		local t = now
		local lastKey = ""
		while t < now + 40 * 3600 and #wins < 8 do
			local ok2, ht = pcall(function() return State.hotTicker(t) end)
			if ok2 and ht and ht.asset then
				local key = tostring(ht.windowIndex)
				if key ~= lastKey then
					local lo, hi = t - 1500, t
					for _ = 1, 8 do
						local mid = (lo + hi) / 2
						local ok3, h3 = pcall(function() return State.hotTicker(mid) end)
						if ok3 and h3 and tostring(h3.windowIndex) == key then hi = mid else lo = mid end
					end
					table.insert(wins, {
						asset = ht.asset.id,
						ticker = ht.asset.ticker or ht.asset.id,
						start = hi, endsAt = ht.endsAt, win = key,
					})
					lastKey = key
				end
				t = ht.endsAt + 60
			else
				t = t + 1200
			end
		end
		hotCal.windows = wins
		hotCal.stamp = os.clock()
		if #wins > 0 then
			local parts = {}
			for _, w in ipairs(wins) do
				parts[#parts+1] = string.format("%s @+%dh", w.ticker, math.floor((w.start - now) / 3600))
			end
			log("🔥 Hot calendar: " .. table.concat(parts, " · "))
		else
			log("🔥 Hot calendar: sin ventanas en 40h")
		end
	end)
	if not ok then log("hotCal ERR: " .. tostring(err)) end
end

-- ══════════════════════════════ EARNINGS (calendario determinista) ════
-- PriceEngine.earningsScheduleFor(seed, asset, day) expone el día y hora
-- exactos de cada publicación (ciclo de 8 días). El resultado (beat/miss)
-- es aleatorio server-side → nunca sostener un trip que cruza la hora.

local earnCal = { times = {}, stamp = 0 }

local function rebuildEarnCal()
	local ok, err = pcall(function()
		local now = State.now()
		local day0 = math.floor(now / 86400)
		local CYCLE = Config.EVENTS.EARNINGS_CYCLE_DAYS or 8
		local map = {}
		local assets = State.listedAssets()
		for d = day0, day0 + 2 do
			for _, asset in ipairs(assets) do
				if asset.class == "stock" and not asset.isIPO
					and not asset.isPlayerStock and asset.idHash then
					if (d + (asset.index or 0) * 3) % CYCLE == 0 then
						local okT, t = pcall(PriceEngine.earningsScheduleFor, State.seed(), asset, d)
						if okT and type(t) == "number" then
							map[asset.id] = map[asset.id] or {}
							table.insert(map[asset.id], t)
						end
					end
				end
			end
		end
		earnCal.times = map
		earnCal.stamp = os.clock()
		local n = 0
		for _ in pairs(map) do n = n + 1 end
		log("📅 Earnings calendario: " .. n .. " assets en 3 días")
	end)
	if not ok then log("earnCal ERR: " .. tostring(err)) end
end

-- ¿el trip [entryT, exitT] cruza una publicación del asset? → hora o nil
local function earningsConflict(id, entryT, exitT)
	local list = earnCal.times[id]
	if not list then return nil end
	for _, t in ipairs(list) do
		if entryT < t + 1200 and exitT > t - 1200 then
			return t
		end
	end
	return nil
end

-- ══════════════════════════════ PIERNAS ZIGZAG (hot windows) ═════════
-- Segmenta la ruta del asset hot en piernas alternantes (pico↔valle) con
-- reversión mínima. Cada pierna garantiza drawdown < umbral por
-- construcción — son los trips "gratis" dentro de la ventana.

local function zigzagLegs(path, threshold)
	local legs = {}
	if #path < 4 then return legs end
	local dir = 0
	local extIdx, extP = 1, path[1].p
	for j = 2, #path do
		local p = path[j].p
		if dir == 0 then
			if p >= path[1].p * (1 + threshold) then
				dir = 1
				extP, extIdx = p, j
			elseif p <= path[1].p * (1 - threshold) then
				dir = -1
				extP, extIdx = p, j
			end
		elseif dir == 1 then
			if p > extP then
				extP, extIdx = p, j
			elseif p <= extP * (1 - threshold) then
				legs[#legs+1] = {
					dir = 1,
					entryI = #legs == 0 and 1 or legs[#legs].exitI,
					exitI = extIdx,
					entryP = #legs == 0 and path[1].p or legs[#legs].exitP,
					exitP = extP,
				}
				dir = -1
				extP, extIdx = p, j
			end
		else
			if p < extP then
				extP, extIdx = p, j
			elseif p >= extP * (1 + threshold) then
				legs[#legs+1] = {
					dir = -1,
					entryI = #legs == 0 and 1 or legs[#legs].exitI,
					exitI = extIdx,
					entryP = #legs == 0 and path[1].p or legs[#legs].exitP,
					exitP = extP,
				}
				dir = 1
				extP, extIdx = p, j
			end
		end
	end
	return legs
end

-- piernas futuras del asset hot dentro de su ventana → oportunidades
local function buildHotLegs(a, tFrom, tTo, tNow)
	local out = {}
	local ok, err = pcall(function()
		local path = {}
		local t0 = math.floor(tFrom / 60) * 60
		for t = t0, tTo, 60 do
			local p = State.assetPrice(a, t)
			if not p or p <= 0 then break end
			path[#path+1] = { t = t, p = p }
		end
		if #path < 8 then return end
		local legs = zigzagLegs(path, 0.035)
		for _, leg in ipairs(legs) do
			local entryT = path[leg.entryI].t
			local exitT = path[leg.exitI].t
			if exitT > tNow + 120 then
				local ret
				if leg.dir == 1 then
					ret = (leg.exitP / leg.entryP - 1) * 100
				else
					ret = (leg.entryP - leg.exitP) / leg.entryP * 100
				end
				if ret >= 2 then
					table.insert(out, {
						id = a.id, dir = leg.dir,
						entryT = entryT, exitT = exitT,
						entryP = leg.entryP, exitP = leg.exitP,
						ret = ret, dd = 3.2, score = ret * 1.1,
						hot = true,
					})
				end
			end
		end
	end)
	if not ok then log("hotLegs ERR: " .. tostring(err)) end
	return out
end

-- ══════════════════════════════ ORÁCULO ══════════════════════════════

local scan = {
	stamp   = 0,
	opps    = {},   -- {id, dir, entryT, exitT, entryP, exitP, ret, dd, score}
	busy    = false,
	progs   = "",
	regime  = nil,  -- {label, rallyScale, crashScale, ...}
}

local recordDriftPrediction -- forward (se define en la sección de trading)
local refreshTop            -- forward (se define en la sección de UI)

local function assetTradeable(a, t0, exitT)
	if a.isMemeCoin or a.isPlayerStock then return false end
	if a.composition and a.class == "index" then return false end
	if State.assetIsDelisted(a, t0) then return false end
	if exitT and State.assetIsDelisted(a, exitT) then return false end
	return true
end

-- análisis de ruta: trips con retorno Y drawdown interno
local function analyzeAsset(a, t0, steps)
	local p0 = State.assetPrice(a, t0)
	if not p0 or p0 <= 0 then return nil end

	local path = {}
	for i = 1, steps do
		local p = State.assetPrice(a, t0 + i * 60)
		if not p or p <= 0 then return nil end
		path[i] = p
	end

	local out = {}
	-- ATR del propio oráculo: volatilidad media por minuto de la ruta
	local atrSum, atrN = 0, 0
	for i = 2, #path do
		atrSum = atrSum + math.abs(path[i] - path[i-1]) / path[i-1]
		atrN = atrN + 1
	end
	local atr = atrN > 0 and atrSum / atrN or 0.01
	local function push(dir, entryI, exitI, entryP, exitP)
		local retPct
		if dir == 1 then
			retPct = (exitP / entryP - 1) * 100
		else
			retPct = (entryP - exitP) / entryP * 100
		end
		if retPct <= 0 then return end
		-- drawdown interno del trip
		local dd = 0
		for i = entryI + 1, exitI do
			local p = path[i]
			local adverse
			if dir == 1 then
				adverse = (entryP - p) / entryP
			else
				adverse = (p - entryP) / entryP
			end
			if adverse > dd then dd = adverse end
		end
		local ddPct = dd * 100
		-- score: retorno penalizado por el dibujo
		local score = retPct - ddPct * 0.8
		-- eficiencia de capital: preferencia suave por trips rápidos
		local holdHours = (exitI - entryI) / 60
		local rank = score / math.sqrt(math.max(holdHours, 0.5))
		table.insert(out, {
			id = a.id, dir = dir,
			entryT = t0 + entryI * 60, exitT = t0 + exitI * 60,
			entryP = entryP, exitP = exitP,
			ret = retPct, dd = ddPct, score = score, rank = rank, atr = atr,
		})
	end

	-- best long trip (trough→peak)
	local minP, minI = p0, 0
	for i = 1, #path do
		local p = path[i]
		if p < minP then minP, minI = p, i end
	end
	local maxAfter, maxI = 0, 0
	for i = math.max(1, minI), #path do
		if path[i] > maxAfter then maxAfter, maxI = path[i], i end
	end
	if maxI > minI then push(1, minI, maxI, minP, maxAfter) end

	-- best short trip (peak→trough)
	local maxP, maxI2 = p0, 0
	for i = 1, #path do
		if path[i] > maxP then maxP, maxI2 = path[i], i end
	end
	local minAfter, minI2 = math.huge, 0
	for i = math.max(1, maxI2), #path do
		if path[i] < minAfter then minAfter, minI2 = path[i], i end
	end
	if minI2 > maxI2 then push(-1, maxI2, minI2, maxP, minAfter) end

	-- entry inmediato (buy now → mejor pico)
	if #path > 0 then
		local bestIdx = 1
		for i = 1, #path do
			if path[i] > path[bestIdx] then bestIdx = i end
		end
		push(1, 0, bestIdx, p0, path[bestIdx])
		-- short now → mejor valle
		local bestIdxS = 1
		for i = 1, #path do
			if path[i] < path[bestIdxS] then bestIdxS = i end
		end
		push(-1, 0, bestIdxS, p0, path[bestIdxS])
	end

	return out
end

local function rescan()
	if scan.busy or not running then return end
	scan.busy = true
	task.spawn(function()
		local ok, err = pcall(function()
			local assets = State.listedAssets()
			local t0 = State.marketNow(assets[1])
			-- clamp al fin del día del juego: al cruzar la medianoche cambia
			-- la clave de precios y priceAt devuelve nil (punto ciego)
			local dayEnd = math.floor(t0 / 86400) * 86400 + 86400
			local steps = math.max(15, math.min(math.floor(CFG.horizonMin),
				math.floor((dayEnd - t0) / 60) - 2))
			local found = {}
			local n = 0
			for idx, a in ipairs(assets) do
				if not running then break end
				if assetTradeable(a, t0, t0 + steps * 60) then
					local ops = analyzeAsset(a, t0, steps)
					if ops then
						for _, o in ipairs(ops) do
							if o.ret - RT_COST * 100 >= 0.4 then
								table.insert(found, o)
							end
						end
					end
				end
				n = idx
				if idx % 3 == 0 then
					scan.progs = string.format("escaneando %d/%d…", idx, #assets)
					task.wait()
				end
			end
			local clean = {}
			for _, o in ipairs(found) do
				local a = State.resolveAsset(o.id)
				if a and assetTradeable(a, o.entryT, o.exitT) then
					table.insert(clean, o)
				end
			end
			table.sort(clean, function(x, y)
				local rx = x.rank or x.score
				local ry = y.rank or y.score
				if math.abs(rx - ry) < 0.05 then return x.exitT < y.exitT end
				return rx > ry
			end)

			-- piernas del asset hot: prioridad absoluta
			if CFG.hotHunter and CFG.hotLegs then
				local nowT = State.now()
				local activeW = hotAt(nowT)
				local nextW
				for _, w in ipairs(hotCal.windows) do
					if w.start > nowT and (not nextW or w.start < nextW.start) then
						nextW = w
					end
				end
				local w = activeW or (nextW and nextW.start - nowT < 1200 and nextW or nil)
				if w then
					local a = State.resolveAsset(w.asset)
					if a then
						local legs = buildHotLegs(a, math.max(nowT, w.start), w.endsAt, nowT)
						for i = #legs, 1, -1 do
							table.insert(clean, 1, legs[i])
						end
						if #legs > 0 then
							log(("🔥 %d piernas zigzag para %s (ventana %s)"):format(
								#legs, w.ticker, os.date("%H:%M", w.endsAt)))
						end
					end
				end
			end

			-- filtro de earnings: nunca sostener un trip que cruza la publicación
			local noEarn = {}
			for _, o in ipairs(clean) do
				if not earningsConflict(o.id, o.entryT, o.exitT) then
					noEarn[#noEarn+1] = o
				end
			end
			clean = noEarn

			scan.opps = clean
			scan.stamp = os.clock()
			scan.progs = string.format("%d oportunidades", #clean)
			if refreshTop then refreshTop() end

			-- régimen
			local okR, mc = pcall(function() return State.marketCycle(t0) end)
			scan.regime = okR and mc or nil

			log(("Rescan: %d assets → %d opps, top=%s %s score=%.1f%% (ret %.1f%%, dd %.1f%%)"):format(
				n, #clean,
				clean[1] and clean[1].id or "—",
				clean[1] and (clean[1].dir == 1 and "LONG" or "SHORT") or "",
				clean[1] and clean[1].score or 0,
				clean[1] and clean[1].ret or 0,
				clean[1] and clean[1].dd or 0))

			-- radar: nuevas predicciones a 3 min
			recordDriftPrediction()
		end)
		if not ok then log("ERROR rescan: " .. tostring(err)) end
		scan.busy = false
	end)
end

-- ══════════════════════════════ LIBRO COMPLETO ══════════════════════

local function bookVWAP(a, t, qty, dir)
	local ok, book = pcall(function()
		return PriceEngine.orderBook(State.seed(), a, t)
	end)
	if not ok or not book then return nil, nil end
	local levels = dir == 1 and book.asks or book.bids
	if not levels or #levels == 0 then return nil, nil end
	local remaining, cost, filled = qty, 0, 0
	for _, lv in ipairs(levels) do
		local take = math.min(remaining, lv.size)
		cost = cost + take * lv.price
		filled = filled + take
		remaining = remaining - take
		if remaining <= 0 then break end
	end
	if filled <= 0 then return nil, nil end
	local vwap = cost / filled
	local touch = levels[1].price
	if touch <= 0 then return nil, nil end
	-- sanity: deslizamiento absurdo → usa el touch
	if math.abs(vwap / touch - 1) > 0.03 then vwap = touch end
	return vwap, filled
end

-- ══════════════════════════════ TRADING ══════════════════════════════

local botPlans = {}     -- [posIndex] = plan
local blacklist = {}    -- [id] = hasta os.clock()

-- persistencia de planes: continuidad perfecta entre recargas
local PLAN_FILE = "oracle_plans.json"
local restoredPlans = {}
do
	local okP, data = pcall(function()
		return HttpService:JSONDecode(readfile(PLAN_FILE))
	end)
	if okP and type(data) == "table" then
		for k, v in pairs(data) do
			if type(v) == "table" then restoredPlans[k] = v end
		end
	end
end

local function savePlans()
	pcall(function()
		local out = {}
		for _, plan in pairs(botPlans) do
			out[plan.id .. (plan.dir == 1 and "L" or "S")] = {
				id = plan.id, dir = plan.dir,
				exitT = plan.exitT, exitP = plan.exitP,
				entryP = plan.entryP, entryRef = plan.entryRef,
				hot = plan.hot, stopInit = plan.stopInit,
			}
		end
		writefile(PLAN_FILE, HttpService:JSONEncode(out))
	end)
end

local pendingLimits = {} -- [id] = {trigger, entryT, placedAt, dir, exitT, exitP, ret, dd, margin}
local driftQ = {}       -- [id] = {t, p} predicción a 3 min para el radar
local driftEma = {}     -- [id] = error relativo medio (0..)
local fedBlocked = false

-- radar de impacts: error medio de predicción → factor de riesgo global
local function driftRiskFactor()
	local sum, n = 0, 0
	for _, v in pairs(driftEma) do
		sum = sum + v
		n = n + 1
	end
	if n == 0 then return 1 end
	local avg = sum / n
	return math.clamp(1 - avg * 6, 0.5, 1)
end

-- asigna la declaración adelantada que rescan captura
recordDriftPrediction = function()
	pcall(function()
		local tNow = State.now()
		-- predicciones nuevas para posiciones y top opps
		local watch = {}
		for _, plan in pairs(botPlans) do watch[plan.id] = true end
		for i = 1, math.min(5, #scan.opps) do watch[scan.opps[i].id] = true end
		for id in pairs(watch) do
			if not driftQ[id] then
				local a = State.resolveAsset(id)
				if a then
					local t = State.marketNow(a)
					local p = State.assetPrice(a, t + 180)
					if p and p > 0 then
						driftQ[id] = { t = tNow, p = p }
					end
				end
			end
		end
	end)
end

local function evaluateDrift()
	pcall(function()
		local tNow = State.now()
		local touched = false
		for id, d in pairs(driftQ) do
			if tNow >= d.t + 180 then
				local a = State.resolveAsset(id)
				if a then
					local actual = State.assetPrice(a, State.marketNow(a))
					if actual and actual > 0 then
						local err = math.abs(actual - d.p) / d.p
						driftEma[id] = (driftEma[id] or 0) * 0.7 + err * 0.3
						if err > 0.02 then
							touched = true
							log(("⚡ radar: %s se desvió %.1f%% del predicho — posible impact"):format(id, err * 100))
						end
					end
				end
				driftQ[id] = nil
			end
		end
		if touched and not scan.busy then
			task.defer(rescan)
		end
	end)
end

local function planForIdDir(id, dir)
	for _, plan in pairs(botPlans) do
		if plan.id == id and plan.dir == dir then return plan end
	end
	return nil
end

-- elimina planes duplicados para id+dir (conserva keep si se pasa)
local function pruneDuplicatePlans(id, dir, keep)
	for k, plan in pairs(botPlans) do
		if plan ~= keep and plan.id == id and plan.dir == dir then
			botPlans[k] = nil
		end
	end
end

local function resolvePosition(plan)
	local pos = State.profile.positions or {}
	for i = #pos, 1, -1 do
		local p = pos[i]
		if p and p.id == plan.id then
			local isLong = (tonumber(p.qty) or 0) > 0
			if (plan.dir == 1) == isLong then
				return i, p
			end
		end
	end
	return nil
end

local function closePlan(plan, reason, fraction)
	local i = resolvePosition(plan)
	if not i then
		for k, pl in pairs(botPlans) do
			if pl == plan then botPlans[k] = nil end
		end
		return
	end
	local ok, res = pcall(function()
		return State.trade({action = "close", index = i, fraction = fraction or 1})
	end)
	if ok and res and res.ok then
		local pnl = tonumber(res.netPnl) or tonumber(res.pnl) or 0
		local partial = (fraction or 1) < 1
		log(("CLOSE%s %s %s @ %s (%s) pnl=%s"):format(
			partial and " parcial" or "",
			plan.dir == 1 and "LONG" or "SHORT", plan.id,
			string.format("%.4g", res.price or 0), reason, money(pnl)))
		gameToast(("%s %s %s · %s%s"):format(
			partial and "Tomo parcial" or (plan.dir == 1 and "Closed LONG" or "Closed SHORT"),
			plan.id, string.format("%.4g", res.price or 0),
			pnl >= 0 and "+" or "", money(pnl)),
			pnl >= 0 and "green" or "red")
		recordClose(plan.id, pnl, reason)
		if not partial then
			-- re-entrada rápida para assets hot (multi-leg dentro de la ventana)
			blacklist[plan.id] = os.clock() + (plan.hot and 45 or 300)
			for k, pl in pairs(botPlans) do
				if pl == plan then botPlans[k] = nil end
			end
			savePlans()
		end
	else
		log(("CLOSE falló %s: %s"):format(plan.id, not ok and tostring(res) or tostring(res and res.err)))
	end
end

-- sizing por confianza (score del trip)
local function confidenceMult(score)
	if score >= 20 then return 1.25
	elseif score >= 8 then return 1.0
	elseif score >= 3 then return 0.8
	else return 0.6 end
end

local function regimeMult(opp)
	if not CFG.regimeAware or not scan.regime then return 1 end
	local rally = tonumber(scan.regime.rallyScale) or 1
	local crash = tonumber(scan.regime.crashScale) or 1
	local longFav = rally >= crash
	if opp.dir == 1 then
		return longFav and 1.15 or 0.7
	else
		return longFav and 0.7 or 1.15
	end
end

-- abre (o añade tramo a) una posición
local function placeOrder(opp, margin, isTranche)
	local a = State.resolveAsset(opp.id)
	if not a then return false end
	local tNow = State.marketNow(a)
	local price = State.assetPrice(a, tNow)
	if not price or price <= 0 then return false end

	-- palanca: base + extra solo para trips élite (score alto, dibujo ínfimo)
	local lev = CFG.leverage
	if CFG.autoLev and not isTranche and (opp.score or 0) >= 25 and (opp.dd or 0) <= 1.5 then
		lev = math.min(CFG.maxAutoLev, CFG.leverage * 2)
	end

	local qty = margin * lev / price
	if qty <= 0 or qty ~= qty then return false end

	-- VWAP del libro para entrada y salida (exacto para órdenes grandes)
	local fillEntry, depthE = bookVWAP(a, tNow, qty, opp.dir)
	local fillExit, depthX = bookVWAP(a, opp.exitT, qty, -opp.dir)
	local entryRef = fillEntry or price
	local netRet
	if fillEntry and fillExit and fillEntry > 0 then
		netRet = opp.dir == 1 and (fillExit / fillEntry - 1) or ((fillEntry - fillExit) / fillEntry)
		if netRet * 100 < CFG.minRet then
			log(("SKIP %s: retorno neto libro %.2f%% < mínimo %.2f%%"):format(opp.id, netRet * 100, CFG.minRet))
			return false
		end
	end

	-- tramos: el total SIEMPRE es `margin` (el bug viejo lo duplicaba)
	local tranchesLeft, trancheQty = 0, 0
	local twap = false
	if not isTranche then
		local nT = math.max(1, CFG.tranches)
		tranchesLeft = nT - 1
		trancheQty = qty / nT
		qty = qty / nT
		-- TWAP por profundidad: si el libro no absorbe, trocea el resto
		if depthE and qty > depthE * 1.3 then
			qty = depthE * 0.85
			tranchesLeft = 2
			trancheQty = math.max(trancheQty, (margin * lev / price - qty) / 2)
			twap = true
		end
	end
	-- respeta profundidad disponible en la salida
	if depthX then qty = math.min(qty, depthX * 0.85) end
	if qty <= 0 or qty ~= qty then return false end

	local ok, res = pcall(function()
		return State.trade({
			action = "open",
			id = opp.id,
			qty = qty,
			direction = opp.dir,
			lev = lev,
		})
	end)

	if ok and res and res.ok then
		if not isTranche then
			pruneDuplicatePlans(opp.id, opp.dir, nil)
			local hot = hotAt(opp.exitT)
			-- stop inicial adaptativo: nunca más apretado que ATR×factor
			local stopPct = math.max(CFG.stopLoss / 100, (opp.atr or 0.01) * CFG.atrStopMult)
			local plan = {
				id = opp.id, dir = opp.dir,
				exitT = opp.exitT, exitP = opp.exitP,
				entryP = res.price or entryRef,
				entryRef = entryRef,
				openedAt = os.clock(),
				tranchesLeft = tranchesLeft,
				trancheQty = trancheQty,
				trancheDeadline = tNow + 600,
				hot = hot ~= nil,
				stopInit = stopPct,
				lev = lev,
			}
			for i = #(State.profile.positions or {}), 1, -1 do
				local p = State.profile.positions[i]
				if p and p.id == opp.id and ((tonumber(p.qty) or 0) > 0) == (opp.dir == 1) then
					plan.key = i
					botPlans[i] = plan
					break
				end
			end
			savePlans()
			local qtyTxt = qty >= 100 and tostring(math.floor(qty)) or string.format("%.2f", qty)
			log(("OPEN %s %s %s @ %s x%d → objetivo %s @ %s (ret %.1f%% dd %.1f%% stop %.1f%%%s%s)"):format(
				opp.dir == 1 and "LONG" or "SHORT",
				opp.id, qtyTxt, string.format("%.4g", plan.entryP), lev,
				os.date("%H:%M", opp.exitT), string.format("%.4g", opp.exitP),
				opp.ret, opp.dd, stopPct * 100,
				plan.hot and " ·🔥hot" or "", twap and " ·TWAP" or ""))
			gameToast(("%s %s %s → obj %.1f%% x%d"):format(
				opp.dir == 1 and "Bought" or "Shorted", opp.id, qtyTxt, opp.ret, lev), "brand")
		else
			log(("TRANCHE %s @ %s"):format(opp.id, string.format("%.4g", res.price or price)))
		end
		return true
	else
		local errTxt = tostring(not ok and res or (res and res.err))
		if errTxt:lower():find("closed") then
			UI._mktClosedUntil = os.clock() + 90
			log("🔒 trade rechazado: mercado cerrado (pausa 90s)")
		end
		log(("OPEN falló %s: %s"):format(opp.id, not ok and tostring(res) or tostring(res and res.err)))
	end
	return false
end

-- ══════════════════════════════ ADOPCIÓN DE HUÉRFANAS ════════════════

local function adoptOrphans()
	local pos = State.profile.positions or {}
	for i = 1, #pos do
		local p = pos[i]
		if p and p.id then
			local dir = (tonumber(p.qty) or 0) > 0 and 1 or -1
			if pendingLimits[p.id] then
				-- hay una orden límite en curso para este asset: la llenada hará el plan
			elseif not planForIdDir(p.id, dir) then
				local a = State.resolveAsset(p.id)
				if a then
					local tNow = State.marketNow(a)
					local price = State.assetPrice(a, tNow)
					if price and price > 0 then
						-- ¿hay snapshot persistido válido para este plan?
						local snap = restoredPlans[p.id .. (dir == 1 and "L" or "S")]
						local plan = {
							id = p.id, dir = dir,
							entryP = price,
							entryRef = price,
							openedAt = os.clock(),
							adopted = true,
							tranchesLeft = 0,
							trancheQty = 0,
							trancheDeadline = 0,
							hot = hotAt(tNow) ~= nil and hotAt(tNow).asset == p.id,
						}
						if snap and tonumber(snap.exitT) and tonumber(snap.exitT) > tNow + 60 then
							plan.exitT = tonumber(snap.exitT)
							plan.exitP = tonumber(snap.exitP) or price
							plan.entryRef = tonumber(snap.entryRef) or price
							plan.stopInit = tonumber(snap.stopInit)
							plan.hot = snap.hot or plan.hot
							restoredPlans[p.id .. (dir == 1 and "L" or "S")] = nil
						else
							local fresh = analyzeAsset(a, tNow, math.min(480, CFG.horizonMin))
							local best
							if fresh then
								for _, fo in ipairs(fresh) do
									if fo.dir == dir and fo.entryT <= tNow + 60 then
										if not best or fo.score > best.score then best = fo end
									end
								end
							end
							if best and best.score > 0.5 then
								plan.exitT = best.exitT
								plan.exitP = best.exitP
							else
								plan.exitT = tNow + 3600
								plan.exitP = State.assetPrice(a, plan.exitT) or price
							end
						end
						botPlans[i] = plan
						savePlans()
						log(("ADOPtada %s %s @ %s → objetivo %s @ %s"):format(
							dir == 1 and "LONG" or "SHORT", p.id,
							string.format("%.4g", price),
							os.date("%H:%M", plan.exitT), string.format("%.4g", plan.exitP)))
					end
				end
			end
		end
	end
end

-- ══════════════════════════════ CEREBRO ══════════════════════════════

local function brainTick()
	if not running then return end
	local profile = State.profile

	pcall(adoptOrphans)
	evaluateDrift()

	-- 1) gestionar posiciones
	local tNow = State.now()
	for key, plan in pairs(botPlans) do
		local a = State.resolveAsset(plan.id)
		if not a then
			botPlans[key] = nil
		else
			local price = State.assetPrice(a, tNow)
			if price and price > 0 then
				local reason
				-- peak alcanzado
				if plan.dir == 1 and price >= plan.exitP * 0.997 then
					reason = "peak"
				elseif plan.dir == -1 and price <= plan.exitP * 1.003 then
					reason = "peak"
				end
				-- stop con trailing (inicial adaptativo por ATR)
				if not reason then
					local trailPct = plan.hot and CFG.trailHot or CFG.trail
					local baseStop = plan.stopInit or CFG.stopLoss / 100
					if plan.dir == 1 then
						local hi = math.max(plan.hi or plan.entryP, price)
						plan.hi = hi
						plan.stopP = math.max(
							plan.stopP or plan.entryP * (1 - baseStop),
							hi * (1 - trailPct / 100))
						if price <= plan.stopP then reason = "stop" end
					else
						local lo = math.min(plan.lo or plan.entryP, price)
						plan.lo = lo
						plan.stopP = math.min(
							plan.stopP or plan.entryP * (1 + baseStop),
							lo * (1 + trailPct / 100))
						if price >= plan.stopP then reason = "stop" end
					end
				end
				-- edad máxima
				if not reason and os.clock() - plan.openedAt > CFG.maxHoldMin * 60 then
					reason = "max-hold"
				end
				-- hora objetivo (o fin de ventana hot o earnings)
				if not reason then
					local effExit = plan.exitT
					if plan.hot then
						local w = hotAt(plan.exitT) or hotAt(tNow)
						if w then effExit = math.min(effExit, w.endsAt - 600) end
					end
					local ec = earningsConflict(plan.id, tNow, plan.exitT)
					if ec then effExit = math.min(effExit, ec - 1200) end
					if tNow >= effExit - 15 then reason = "target" end
				end
				-- beneficio parcial: cierra 50% al 60% del objetivo (no hot)
				if not reason and CFG.takePartial and not plan.hot and not plan.halfDone then
					local denom = plan.dir == 1
						and (plan.exitP - plan.entryP)
						or (plan.entryP - plan.exitP)
					if denom ~= 0 then
						local progress = plan.dir == 1
							and (price - plan.entryP) / denom
							or (plan.entryP - price) / denom
						if progress >= 0.6 and progress < 0.95 and price > 0 then
							plan.halfDone = true
							closePlan(plan, "profit-50%", 0.5)
						end
					end
				end
				if reason then
					closePlan(plan, reason)
				end
			end
		end
	end

	-- 2) tramos pendientes
	for _, plan in pairs(botPlans) do
		if plan.tranchesLeft > 0 and tNow <= plan.trancheDeadline then
			local a = State.resolveAsset(plan.id)
			if a then
				local price = State.assetPrice(a, State.marketNow(a))
				if price and price > 0 then
					-- añade tramo si volvió al valle o se acaba el plazo
					if price <= plan.entryRef * 1.005 or tNow > plan.trancheDeadline - 60 then
						local margin = plan.trancheQty * price
						placeOrder({ id = plan.id, dir = plan.dir, exitT = plan.exitT, exitP = plan.exitP },
							margin, true)
						plan.tranchesLeft = plan.tranchesLeft - 1
					end
				end
			end
		end
	end

	-- 3) gestionar órdenes límite pendientes
	for id, pl in pairs(pendingLimits) do
		local found, orderIdx, order
		for i, o in ipairs(State.profile.orders or {}) do
			if o.assetId == id or o.id == id then
				found, orderIdx, order = true, i, o
				break
			end
		end
		local posNow = false
		for _, p in ipairs(State.profile.positions or {}) do
			if p.id == id and ((tonumber(p.qty) or 0) > 0) == (pl.dir == 1) then
				posNow = true
				break
			end
		end
		if posNow then
			-- ¡llenada! adopta el plan (limpia duplicados del mismo id+dir)
			pruneDuplicatePlans(id, pl.dir, nil)
			local plan = {
				id = id, dir = pl.dir,
				exitT = pl.exitT, exitP = pl.exitP,
				entryP = pl.trigger, entryRef = pl.trigger,
				openedAt = os.clock(),
				tranchesLeft = 0, trancheQty = 0, trancheDeadline = 0,
				hot = hotAt(State.now()) ~= nil and hotAt(State.now()).asset == id,
			}
			for i = #(State.profile.positions or {}), 1, -1 do
				local p = State.profile.positions[i]
				if p and p.id == id and ((tonumber(p.qty) or 0) > 0) == (pl.dir == 1) then
					botPlans[i] = plan
					break
				end
			end
			log(("LIMIT llenada %s @ %s → objetivo %s @ %s"):format(
				id, string.format("%.4g", pl.trigger),
				os.date("%H:%M", pl.exitT), string.format("%.4g", pl.exitP)))
			gameToast(("Limit llenada %s @ %.4g"):format(id, pl.trigger), "green")
			savePlans()
			pendingLimits[id] = nil
		elseif not found then
			pendingLimits[id] = nil -- cancelada o rechazada
			log("LIMIT " .. id .. " desapareció sin llenar")
		elseif os.clock() - pl.placedAt > 900 then
			-- expiró: cancela
			local okC, resC = pcall(function()
				return State.trade({action = "cancelOrder", index = orderIdx,
					expectedAssetId = id, expectedCreatedAt = order.createdAt})
			end)
			log(string.format("LIMIT %s expiró → cancel=%s", id,
				tostring(okC and resC and resC.ok)))
			gameToast("Limit cancelada " .. id, "gold")
			pendingLimits[id] = nil
		end
	end

	-- 3.5) abrir nuevas
	if CFG.auto and not scan.busy then
		-- mercado cerrado (auto-aprendido de fallos de trade)
		if UI._mktClosedUntil and os.clock() < UI._mktClosedUntil then
			if not UI._mktClosedWarned then
				UI._mktClosedWarned = true
				log("🔒 mercado cerrado — sin entradas hasta que reabra")
			end
			return
		end
		UI._mktClosedWarned = false
		-- Fed guard: countdown del UI del juego
		fedBlocked = false
		if CFG.fedGuard then
			if UI._fedLive or (UI._fedCountdown and UI._fedCountdown < 240) then
				fedBlocked = true
			end
		end
		if fedBlocked then
			if not UI._fedWarned then
				UI._fedWarned = true
				log("🏛 Fed inminente/en vivo — sin entradas nuevas")
			end
			return
		end
		UI._fedWarned = false

		local nOpen = 0
		for _ in pairs(botPlans) do nOpen = nOpen + 1 end
		for _ in pairs(pendingLimits) do nOpen = nOpen + 1 end
		nOpen = math.max(nOpen, #(State.profile.positions or {}))
		if nOpen < CFG.maxPositions then
			local nw = State.netWorth()
			local riskF = driftRiskFactor()
			local margin = nw * CFG.sizingPct / 100 * riskF
			local availCash = (profile.cash or 0) - nw * CFG.reservePct / 100
			if availCash < 1 then availCash = (profile.cash or 0) * 0.95 end
			if margin > availCash then margin = availCash * 0.95 end
			if margin > (profile.cash or 0) * 0.95 then margin = (profile.cash or 0) * 0.95 end
			if margin > 1 then
				-- estado hot: ¿ventana activa o inminente?
				local activeHot = hotAt(tNow)
				local nextHot
				for _, w in ipairs(hotCal.windows) do
					if w.start > tNow and (not nextHot or w.start < nextHot.start) then
						nextHot = w
					end
				end

				local held = {}
				for _, plan in pairs(botPlans) do held[plan.id] = true end
				for _, p in ipairs(State.profile.positions or {}) do held[p.id] = true end
				for id in pairs(pendingLimits) do held[id] = true end

				-- sectores ya cubiertos
				local heldSectors = {}
				if CFG.sectorDiversity then
					pcall(function()
						for _, p in ipairs(State.profile.positions or {}) do
							local a = State.resolveAsset(p.id)
							if a then
								local sk = Config.sectorKey(a)
								if sk then heldSectors[sk] = true end
							end
						end
					end)
				end

				for _, opp in ipairs(scan.opps) do
					if (opp.dir == 1 or CFG.allowShorts)
						and not held[opp.id]
						and not (blacklist[opp.id] and blacklist[opp.id] > os.clock()) then

						local isHotAsset = false
						local skipThis = false
						if CFG.hotHunter then
							if activeHot then
								if opp.id ~= activeHot.asset then
									skipThis = true -- espera al evento grande
								else
									isHotAsset = true
								end
							elseif nextHot and (nextHot.start - tNow) < 2700 then
								-- ventana en <45 min: no abrir nada nuevo
								break
							else
								-- ¿este asset tiene ventana hot propia dentro del trip?
								for _, w in ipairs(hotCal.windows) do
									if w.asset == opp.id and w.start <= opp.exitT and w.endsAt >= opp.entryT then
										isHotAsset = true
										break
									end
								end
							end
						end
						if not skipThis then

						-- re-verificación fresca
						local a = State.resolveAsset(opp.id)
						if a and assetTradeable(a, tNow, opp.exitT) then
							local dayEnd2 = math.floor(tNow / 86400) * 86400 + 86400
							local steps = math.max(15, math.min(math.floor((opp.exitT - tNow) / 60) + 2,
								math.floor((dayEnd2 - tNow) / 60) - 2))
							local fresh = analyzeAsset(a, tNow, steps)
							local pick
							if fresh then
								for _, fo in ipairs(fresh) do
									if fo.dir == opp.dir and math.abs(fo.exitT - opp.exitT) < 300 then
										pick = fo
										break
									end
								end
							end
											if pick and earningsConflict(pick.id, pick.entryT, pick.exitT) then
								pick = nil -- el trip fresco cruza una publicación
							end
							if pick then
								-- el filtro de dibujo se adapta a la volatilidad del asset
								local stopCapPct = math.max(CFG.stopLoss, (pick.atr or 0.01) * CFG.atrStopMult * 100)
								if not (pick.score - RT_COST * 100 >= CFG.minRet and pick.dd <= stopCapPct) then
									pick = nil
								end
							end
							if pick then

								-- diversidad por sector
								local sectorOK = true
								if CFG.sectorDiversity and not isHotAsset then
									pcall(function()
										local sk = Config.sectorKey(a)
										if sk and heldSectors[sk] then sectorOK = false end
									end)
								end

								-- sizing por confianza + hot boost + régimen + radar
								local eff = margin * confidenceMult(pick.score) * regimeMult(pick)
								if isHotAsset then eff = eff * 1.3 end
								if eff > (profile.cash or 0) * 0.95 then
									eff = (profile.cash or 0) * 0.95
								end

								local lead = pick.entryT - tNow
								if sectorOK and CFG.useLimits and lead > 120 and lead <= 900 then
									-- valle/cresta a 2-15 min: orden límite en el punto exacto
									local trigger = pick.dir == 1
										and pick.entryP * 1.002
										or pick.entryP * 0.998
									local okL, resL = pcall(function()
										return State.trade({
											action = "placeLimit",
											id = pick.id,
											margin = eff,
											direction = pick.dir,
											lev = CFG.leverage,
											trigger = trigger,
										})
									end)
									if okL and resL and resL.ok then
										pendingLimits[pick.id] = {
											trigger = trigger, entryT = pick.entryT,
											placedAt = os.clock(), dir = pick.dir,
											exitT = pick.exitT, exitP = pick.exitP,
											ret = pick.ret, dd = pick.dd, margin = eff,
										}
										log(("LIMIT %s %s trigger %.4g (punto óptimo @+%d min)"):format(
											pick.dir == 1 and "LONG" or "SHORT", pick.id,
											trigger, math.floor(lead / 60)))
										gameToast(("Limit %s @ %.4g"):format(pick.id, trigger), "brand")
									else
										local errL = tostring(not okL and resL or (resL and resL.err))
										if errL:lower():find("closed") then
											UI._mktClosedUntil = os.clock() + 90
											log("🔒 límite rechazado: mercado cerrado (pausa 90s)")
										end
										log(("LIMIT falló %s: %s"):format(pick.id, errL))
									end
								elseif sectorOK and lead <= CFG.entryLead then
									if eff > 1 then
										placeOrder(pick, eff, false)
									end
								end
							end
							break -- un intento por tick
						end
						end
					end
				end
			end
		end
	end
end

-- ══════════════════════════════ OPERACIÓN DE PRUEBA ══════════════════

local function testTrade()
	local opp = scan.opps[1]
	if not opp then log("No hay oportunidades escaneadas aún") return end
	local cash = State.profile.cash or 0
	local margin = cash * CFG.testPct / 100
	log(("TEST: abriendo %s %s con %s…"):format(opp.dir == 1 and "LONG" or "SHORT", opp.id, money(margin)))
	local a = State.resolveAsset(opp.id)
	local price = a and State.assetPrice(a, State.marketNow(a))
	if not price then log("TEST: sin precio") return end
	local ok, res = pcall(function()
		return State.trade({
			action = "open",
			id = opp.id,
			qty = margin / price,
			direction = opp.dir,
			lev = 1,
		})
	end)
	if ok and res and res.ok then
		log(("TEST fill: price=%s filledQty=%s slippage=%.3f%% clampedFrom=%s"):format(
			string.format("%.4g", res.price or 0),
			tostring(res.filledQty),
			(res.fillSlippage or 0) * 100,
			tostring(res.clampedFrom)))
		log(("TEST predicho: entry≈%.4g exit≈%.4g (+%.2f%%)"):format(opp.entryP, opp.exitP, opp.ret))
	else
		log("TEST falló: " .. (not ok and tostring(res) or tostring(res and res.err)))
	end
end

-- ══════════════════════════════ UI (Rayfield Gen2) ═══════════════════

-- destruye ventanas viejas de recargas anteriores
local function destroyStaleUI()
	if getgenv()._ORACLE_RF_WINDOW then
		pcall(function() getgenv()._ORACLE_RF_WINDOW:Destroy() end)
		getgenv()._ORACLE_RF_WINDOW = nil
	end
	local containers = { LP.PlayerGui }
	local okH, hui = pcall(function() return gethui() end)
	if okH and hui then table.insert(containers, hui) end
	for _, cont in ipairs(containers) do
		pcall(function()
			for _, c in ipairs(cont:GetChildren()) do
				if c:IsA("ScreenGui") then
					local hit, budget = false, 500
					for _, d in ipairs(c:GetDescendants()) do
						budget = budget - 1
						if budget < 0 then break end
						if d:IsA("TextLabel") then
							local t = d.Text or ""
							if t:find("Oracle Trader", 1, true) or t:find("ProbeX", 1, true) then
								hit = true
								break
							end
						end
					end
					if hit then
						c:Destroy()
						print("[Oracle] ventana vieja destruida: " .. c.Name)
					end
				end
			end
		end)
	end
end

-- mini-panel de estado propio (TextLabel directo)
local function buildOverlay()
	local okH, hui = pcall(function() return gethui() end)
	local parent = okH and hui or game:GetService("CoreGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "OracleStatusOverlay"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 50
	local fr = Instance.new("Frame")
	fr.Size = UDim2.fromOffset(235, 108)
	fr.Position = UDim2.new(0, 10, 0, 10)
	fr.BackgroundColor3 = Color3.fromRGB(15, 16, 20)
	fr.BackgroundTransparency = 0.2
	fr.BorderSizePixel = 0
	fr.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = fr
	local txt = Instance.new("TextLabel")
	txt.Name = "StatusText"
	txt.Size = UDim2.new(1, -14, 1, -10)
	txt.Position = UDim2.new(0, 8, 0, 5)
	txt.BackgroundTransparency = 1
	txt.TextXAlignment = Enum.TextXAlignment.Left
	txt.TextYAlignment = Enum.TextYAlignment.Top
	txt.TextSize = 12
	txt.Font = Enum.Font.Code
	txt.TextColor3 = Color3.fromRGB(235, 235, 240)
	txt.TextWrapped = true
	txt.Text = "Oracle Trader v2\niniciando…"
	txt.Parent = fr
	sg.Parent = parent
	UI.overlayText = txt
	return sg
end

local function buildUI()
	local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
	local window = Rayfield:CreateWindow({
		name = "Oracle Trader v2",
		subtitle = "RSE2 · oráculo + hot hunter",
		configuration = { autoSave = true, autoLoad = true, fileName = "OracleTrader" },
	})
	UI.window = window
	getgenv()._ORACLE_RF_WINDOW = window

	local tabBot = window:CreateTab({ name = "Bot", icon = "zap" })
	local tabTop = window:CreateTab({ name = "Top", icon = "chart" })
	local tabStats = window:CreateTab({ name = "Stats", icon = "trophy" })
	local tabCfg = window:CreateTab({ name = "Config", icon = "settings" })
	local tabLog = window:CreateTab({ name = "Log", icon = "terminal" })

	UI.status = tabBot:CreateText({
		name = "Estado",
		text = "Escaneando el futuro…",
	})

	UI._autoToggle = tabBot:CreateToggle({
		name = "AUTO-TRADE",
		description = "Opera solo las mejores decisiones",
		value = false,
		callback = function(v)
			CFG.auto = v
			log(v and "▶ AUTO-TRADE activado" or "⏸ AUTO-TRADE desactivado")
		end,
	})

	tabBot:CreateButton({
		name = "Rescanear ahora",
		callback = function()
			rescan()
			if CFG.hotHunter then rebuildHotCal() end
		end,
	})

	tabBot:CreateButton({
		name = "Operación de prueba (" .. CFG.testPct .. "% cash)",
		description = "Abre la mejor oportunidad con monto mínimo",
		callback = function() task.spawn(testTrade) end,
	})

	tabBot:CreateButton({
		name = "Cerrar TODO",
		callback = function()
			task.spawn(function()
				local ok, res = pcall(function() return State.trade({action = "closeAll"}) end)
				log(ok and (res and res.ok and "Todo cerrado" or ("closeAll: " .. tostring(res and res.err))) or "closeAll error")
				-- los planes se limpian solos al adoptar/detectar ausencia
				for k in pairs(botPlans) do botPlans[k] = nil end
			end)
		end,
	})

	UI.top = tabTop:CreateConsole({
		name = "Mejores oportunidades",
		height = 250,
		follow = false,
		maxLines = 80,
	})

	refreshTop = function()
		local lines = {}
		local now = State.now()
		if CFG.hotHunter and #hotCal.windows > 0 then
			lines[#lines+1] = "🔥 CALENDARIO HOT:"
			for _, w in ipairs(hotCal.windows) do
				lines[#lines+1] = string.format("   %s ventana %+dh → %+dh",
					w.ticker, math.floor((w.start - now) / 3600), math.floor((w.endsAt - now) / 3600))
			end
			lines[#lines+1] = ""
		end
		-- próximos earnings
		local nextEarn, nextEarnT
		for id, list in pairs(earnCal.times) do
			for _, t in ipairs(list) do
				if t > now and (not nextEarnT or t < nextEarnT) then
					nextEarn, nextEarnT = id, t
				end
			end
		end
		if nextEarn then
			lines[#lines+1] = string.format("📅 Próximo earnings: %s en %.1fh", nextEarn, (nextEarnT - now) / 3600)
			lines[#lines+1] = ""
		end
		for i = 1, math.min(12, #scan.opps) do
			local o = scan.opps[i]
			local minsIn = (o.entryT - now) / 60
			local holdMin = (o.exitT - o.entryT) / 60
			lines[#lines+1] = string.format("%2d. %-7s %-5s +%.1f%% (dd %.1f%%%s) entra+%dm · hold %dm",
				i, o.id, o.dir == 1 and "LONG" or "SHORT", o.score, o.dd,
				o.hot and " 🔥" or "", math.floor(minsIn), math.floor(holdMin))
		end
		if #lines == 0 then lines[1] = "(sin datos — espera el rescan)" end
		UI._topStr = table.concat(lines, "\n")
	end

	tabTop:CreateButton({
		name = "Refrescar lista",
		callback = function() if refreshTop then refreshTop() end end,
	})

	-- Stats
	UI.stNW = tabStats:CreateStat({
		name = "NetWorth", prefix = "$", value = 0,
	})
	UI.stPnl = tabStats:CreateStat({
		name = "PnL sesión", prefix = "$", value = 0,
	})
	UI.stWR = tabStats:CreateStat({
		name = "Win rate", suffix = "%", value = 0,
	})
	UI.stN = tabStats:CreateStat({
		name = "Trades", value = stats.wins + stats.losses,
	})
	UI.stTrades = tabStats:CreateConsole({
		name = "Últimos cierres",
		height = 170,
		follow = false,
		maxLines = 40,
	})
	UI._statsDirty = true

	tabCfg:CreateSlider({
		name = "Tamaño por trade",
		description = "% del netWorth (base, antes de confianza)",
		range = {5, 100}, increment = 5, value = CFG.sizingPct, suffix = "%",
		callback = function(v) CFG.sizingPct = v end,
	})
	tabCfg:CreateSlider({
		name = "Retorno mínimo",
		range = {0.5, 10}, increment = 0.5, value = CFG.minRet, suffix = "%",
		callback = function(v) CFG.minRet = v end,
	})
	tabCfg:CreateSlider({
		name = "Horizonte del oráculo",
		range = {30, 1440}, increment = 30, value = CFG.horizonMin, suffix = " min",
		callback = function(v) CFG.horizonMin = v end,
	})
	tabCfg:CreateSlider({
		name = "Posiciones máximas",
		range = {1, 4}, increment = 1, value = CFG.maxPositions,
		callback = function(v) CFG.maxPositions = v end,
	})
	tabCfg:CreateSlider({
		name = "Stop-loss",
		range = {1, 15}, increment = 1, value = CFG.stopLoss, suffix = "%",
		callback = function(v) CFG.stopLoss = v end,
	})
	tabCfg:CreateSlider({
		name = "Trailing stop",
		range = {3, 30}, increment = 1, value = CFG.trail, suffix = "%",
		callback = function(v) CFG.trail = v end,
	})
	tabCfg:CreateSlider({
		name = "Hold máximo",
		range = {15, 480}, increment = 15, value = CFG.maxHoldMin, suffix = " min",
		callback = function(v) CFG.maxHoldMin = v end,
	})
	tabCfg:CreateSlider({
		name = "Tramos por entrada",
		description = "divide la orden cerca del valle",
		range = {1, 3}, increment = 1, value = CFG.tranches,
		callback = function(v) CFG.tranches = v end,
	})
	tabCfg:CreateSlider({
		name = "Pérdida diaria máx",
		range = {5, 50}, increment = 5, value = CFG.dailyLossPct, suffix = "%",
		callback = function(v) CFG.dailyLossPct = v end,
	})
	tabCfg:CreateToggle({
		name = "Permitir shorts",
		value = false,
		callback = function(v) CFG.allowShorts = v end,
	})
	tabCfg:CreateToggle({
		name = "Límites en el valle",
		description = "órdenes límite en el punto óptimo (2-15 min)",
		value = true,
		callback = function(v) CFG.useLimits = v end,
	})
	tabCfg:CreateToggle({
		name = "Fed guard",
		description = "no abrir cerca de la decisión de la Fed",
		value = true,
		callback = function(v) CFG.fedGuard = v end,
	})
	tabCfg:CreateToggle({
		name = "Diversidad por sector",
		value = true,
		callback = function(v) CFG.sectorDiversity = v end,
	})
	tabCfg:CreateToggle({
		name = "Beneficio parcial",
		description = "cierra 50% al llegar al 60% del objetivo",
		value = true,
		callback = function(v) CFG.takePartial = v end,
	})
	tabCfg:CreateToggle({
		name = "Piernas zigzag hot",
		description = "tradea cada swing dentro de la ventana hot",
		value = true,
		callback = function(v) CFG.hotLegs = v end,
	})
	tabCfg:CreateSlider({
		name = "Reserva de cash",
		description = "% del NW que nunca se opera",
		range = {0, 50}, increment = 5, value = CFG.reservePct, suffix = "%",
		callback = function(v) CFG.reservePct = v end,
	})
	tabCfg:CreateToggle({
		name = "Auto-apalancamiento élite",
		description = "x2 extra solo en trips con score>=25 y dd<1.5%",
		value = true,
		callback = function(v) CFG.autoLev = v end,
	})
	tabCfg:CreateSlider({
		name = "Techo auto-palanca",
		range = {1, 3}, increment = 1, value = CFG.maxAutoLev, suffix = "x",
		callback = function(v) CFG.maxAutoLev = v end,
	})
	tabCfg:CreateSlider({
		name = "ATR stop ×",
		description = "stop inicial = max(fijo, volatilidad×factor)",
		range = {1, 6}, increment = 0.5, value = CFG.atrStopMult, suffix = "×",
		callback = function(v) CFG.atrStopMult = v end,
	})
	tabCfg:CreateToggle({
		name = "Hot Hunter",
		description = "prioriza ventanas hot ticker",
		value = true,
		callback = function(v) CFG.hotHunter = v end,
	})
	tabCfg:CreateToggle({
		name = "Régimen consciente",
		description = "sesgo long/short según marketCycle",
		value = true,
		callback = function(v) CFG.regimeAware = v end,
	})

	UI.console = tabLog:CreateConsole({
		name = "Actividad",
		height = 260,
		follow = true,
		maxLines = 200,
	})

	-- seguridad: AUTO siempre OFF al cargar, aunque Rayfield restaure ON
	UI._autoOff = true

	window:Notify({ title = "Oracle Trader v2", content = "Escaneando el futuro…" })
end

-- ══════════════════════════════ ARRANQUE ══════════════════════════════

pcall(destroyStaleUI)

local okUI, errUI = pcall(buildUI)
if not okUI then
	warn("[Oracle] UI falló: " .. tostring(errUI))
	log("UI Rayfield no cargó: " .. tostring(errUI))
end

pcall(buildOverlay)

startNW = State.netWorth()
log(("v2 cargado · NW inicial %s · stats históricas: pnl %s (%dW/%dL)")
	:format(money(startNW), money(stats.pnl), stats.wins, stats.losses))

-- señal de impacts: replan inmediato
conn(State.signals.impacted, function()
	log("⚡ Impact del servidor detectado → replanificando")
	task.defer(rescan)
end)

-- rescan + hot calendar + earnings periódicos
task.spawn(function()
	rebuildHotCal()
	rebuildEarnCal()
	while running do
		rescan()
		if CFG.hotHunter and os.clock() - hotCal.stamp > 600 then
			rebuildHotCal()
		end
		if os.clock() - earnCal.stamp > 600 then
			rebuildEarnCal()
		end
		for _ = 1, CFG.replanSecs * 2 do
			if not running then break end
			task.wait(0.5)
		end
	end
end)

-- cerebro
task.spawn(function()
	while running do
		pcall(brainTick)
		task.wait(2)
	end
end)

-- status: solo calcula; el flusher pinta
task.spawn(function()
	local eqTick = 0
	while running do
		pcall(function()
			local nw = State.netWorth()
			local nOpen = 0
			for _ in pairs(botPlans) do nOpen = nOpen + 1 end
			local reg = scan.regime and scan.regime.label or "?"
			local hotNow = CFG.hotHunter and hotAt(State.now())
			local nLim = 0
			for _ in pairs(pendingLimits) do nLim = nLim + 1 end
			local fedTxt = ""
			if UI._fedLive then
				fedTxt = " · 🏛FED LIVE"
			elseif UI._fedCountdown then
				fedTxt = string.format(" · 🏛Fed %dm", math.floor(UI._fedCountdown / 60))
			end
			UI._statusStr = table.concat({
				"⚡ " .. (CFG.auto and "AUTO ON" or "auto off") ..
					"  ·  pos " .. nOpen .. "/" .. CFG.maxPositions ..
					"  ·  lim " .. nLim ..
					(hotNow and ("  ·  🔥" .. hotNow.ticker) or "") .. fedTxt,
				"NW " .. money(nw) .. "  ·  cash " .. money(State.profile.cash or 0),
				"PnL " .. money(stats.pnl) .. " (" .. stats.wins .. "W/" .. stats.losses .. "L)" ..
					"  ·  " .. reg ..
					"  ·  radar " .. string.format("%d%%", math.floor(driftRiskFactor() * 100)),
				"opps " .. #scan.opps .. "  ·  " .. scan.progs,
			}, "\n")
			UI._statsStr = tostring(#scan.opps)

			-- curva de equity: 1 muestra cada ~30s
			eqTick = eqTick + 1
			if eqTick % 15 == 0 then
				table.insert(stats.equity, { t = os.time(), nw = math.floor(nw) })
				while #stats.equity > 150 do table.remove(stats.equity, 1) end
				if eqTick % 150 == 0 then persistStats() end
			end
		end)
		task.wait(2)
	end
end)

getgenv()._ORACLE_STOP = function()
	running = false
	persistStats()
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	connections = {}
	pcall(function() if UI.window then UI.window:Destroy() end end)
	pcall(function()
		local sg = UI.overlayText and UI.overlayText:FindFirstAncestorOfClass("ScreenGui")
		if sg then sg:Destroy() end
	end)
	log("Oracle detenido")
end

-- control externo
getgenv()._ORACLE = {
	CFG = CFG, scan = scan, plans = botPlans, blacklist = blacklist,
	stats = stats, hotCal = hotCal, UI = UI,
	rescan = rescan, rebuildHotCal = rebuildHotCal, rebuildEarnCal = rebuildEarnCal,
	savePlans = savePlans, persistStats = persistStats,
	isRunning = function() return running end,
}

-- FLUSHER: corre en el HILO PRINCIPAL. Cada elemento en su propio pcall
-- con diagnóstico: un fallo de Rayfield no tira el resto.
local guiWarned = 0
local warnedOnce = {}
local function safePaint(label, fn)
	local ok, err = pcall(fn)
	if not ok and not warnedOnce[label] then
		warnedOnce[label] = true
		warn("[Oracle] paint " .. label .. ": " .. tostring(err))
		print("[Oracle] paint " .. label .. ": " .. tostring(err))
	end
	return ok
end

while running do
	-- el yield puede resetear la identidad del hilo → re-aplicar en cada vuelta
	if typeof(setthreadidentity) == "function" then
		pcall(setthreadidentity, 8)
	end
	local now = os.clock()
	if (UI._lastFlush or 0) + 0.5 <= now then
		UI._lastFlush = now

		if UI._autoOff then
			UI._autoOff = false
			safePaint("autoToggle", function()
				if UI._autoToggle then UI._autoToggle:Set(false, true) end
			end)
		end

		-- overlay propio (prioridad máxima)
		if UI._statusStr and UI.overlayText then
			local okO = safePaint("overlay", function()
				UI.overlayText.Text = UI._statusStr
			end)
			if not okO then
				guiWarned = guiWarned + 1
			end
		end

		-- lee el estado de la Fed del UI del juego (hilo privilegiado)
		safePaint("fedread", function()
			local term = LP.PlayerGui:FindFirstChild("RSETerminal")
			if term then
				local live = term:FindFirstChild("FedLive")
				UI._fedLive = (live ~= nil) and live.Visible or false
				local pill = term:FindFirstChild("FedPill")
				local cd = nil
				if pill and pill:IsA("TextButton") and pill.Visible then
					local m, s = pill.Text:match("(%d+):(%d+)")
					if m then cd = tonumber(m) * 60 + tonumber(s) end
				end
				UI._fedCountdown = cd
			end
		end)

		-- estado en la card de Rayfield
		safePaint("status", function()
			if UI._statusStr and UI.status then
				UI.status:Set(UI._statusStr)
			end
		end)

		-- tarjetas de stats (cada una aislada para diagnóstico)
		if UI._statsDirty then
			local nwV = 0
			pcall(function() nwV = math.floor(State.netWorth()) end)
			local wr = (stats.wins + stats.losses) > 0
				and math.floor(stats.wins / (stats.wins + stats.losses) * 100) or 0
			safePaint("stNW", function() if UI.stNW then UI.stNW:Set(nwV) end end)
			safePaint("stPnl", function() if UI.stPnl then UI.stPnl:Set(math.floor(stats.pnl)) end end)
			safePaint("stWR", function() if UI.stWR then UI.stWR:Set(wr) end end)
			safePaint("stN", function() if UI.stN then UI.stN:Set(stats.wins + stats.losses) end end)
			safePaint("stTrades", function()
				if UI.stTrades then
					local gw, gl, pf = tradeSummary()
					local lines = {}
					lines[#lines+1] = string.format("PF(50) %.2f  ·  ganado %s  ·  perdido %s", pf, money(gw), money(gl))
					lines[#lines+1] = string.format("mejor %s  ·  peor %s", money(stats.bestWin), money(stats.worstLoss))
					lines[#lines+1] = sparkline(stats.equity, 44)
					for i = #stats.trades, math.max(1, #stats.trades - 11), -1 do
						local tr = stats.trades[i]
						lines[#lines+1] = string.format("%s  %-6s %s%s  %s",
							tr.t, tr.id, tr.pnl >= 0 and "+" or "", money(tr.pnl), tr.r)
					end
					if #lines == 3 then lines[#lines+1] = "(sin cierres aún)" end
					UI.stTrades:Set(table.concat(lines, "\n"))
				end
			end)
			UI._statsDirty = false
		end

		-- logs y lista Top
		safePaint("console", function()
			if UI.console then
				if #UI._logQ > 0 then
					local chunk = table.concat(UI._logQ, "\n")
					UI._logQ = {}
					UI.console:Append(chunk)
				end
				if UI._topStr then
					local s = UI._topStr
					UI._topStr = nil
					UI.top:Set(s)
				end
			end
		end)

		if guiWarned >= 3 and guiWarned < 100 then
			guiWarned = 100
			warn("[Oracle] GUI limitado: usa el mini-panel (esquina sup. izq.) y los toasts del juego")
			gameToast("⚠ Oracle: GUI de Rayfield limitado — ver mini-panel y toasts", "gold")
		end
	end
	task.wait(0.25)
end

-- ▸ adaptador del hub: teardown estándar para el universal
getgenv()._HUB_SCRIPT_STOP = function()
	if getgenv()._ORACLE_STOP then
		getgenv()._ORACLE_STOP()
	end
end
