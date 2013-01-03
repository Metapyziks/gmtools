-- -- -- -- -- --
-- nwtable.lua --
-- -- -- -- -- --

if SERVER then AddCSLuaFile("nwtable.lua") end

local _nwtents = {}

NWTInfo = {}
NWTInfo.__index = NWTInfo

NWTInfo._entity = nil
NWTInfo._key = nil

NWTInfo._value = nil

if SERVER then
	util.AddNetworkString("NWTableUpdate")

	NWTInfo._info = nil

	function NWTInfo:SetValue(value)
		self:UpdateTable(self._value, self._info, value, CurTime())
	end

	local _typewrite = {
		[TYPE_NIL] = function(v) end,
		[TYPE_STRING] = function(v) net.WriteString(v) end,
		[TYPE_NUMBER] = function(v) net.WriteFloat(v) end,
		[TYPE_BOOL] = function(v) net.WriteBit(v) end,
		[TYPE_ENTITY] = function(v) net.WriteEntity(v) end
	}

	function NWTInfo:UpdateTable(old, info, new, time)
		local changed = false
		for k, v in pairs(new) do
			if type(k) == "string" and string.GetChar(k, 1) ~= "_" then
				local tid = TypeID(v)
				if tid == TYPE_TABLE then
					if not old[k] then
						old[k] = {}
						info[k] = {}
						changed = true
					end
					if self:UpdateTable(old[k], info[k], v, time) then
						changed = true
					end
				elseif (tid == TYPE_NIL and TypeID(old) ~= TYPE_NIL)
					or (_typewrite[tid] and old[k] ~= v) then
					old[k] = v
					info[k] = time
					changed = true
				end
			end
		end

		for k, v in pairs(old) do
			if not new[k] and old[k] then
				print(k .. " = nil")
				old[k] = nil
				info[k] = time
				changed = true
			end
		end

		if changed then	info._lastupdate = time end
		return changed
	end

	net.Receive("NWTableUpdate", function(len, ply)
		local ent = net.ReadEntity()
		local key = net.ReadString()
		local time = net.ReadFloat()

		if ent and ent._nwts and ent._nwts[key] then
			ent._nwts[key]:SendUpdate(ply, time)
		end
	end)

	function NWTInfo:SendUpdate(ply, since)
		since = since or 0

		if since >= self._info._lastupdate then
			return
		end

		net.Start("NWTableUpdate")
		net.WriteEntity(self._entity)
		net.WriteString(self._key)
		net.WriteFloat(CurTime())
		self:SendTable(self._value, self._info, since)
		net.Send(ply)
	end

	function NWTInfo:SendTable(table, info, since)
		local count = 0
		for k, i in pairs(info) do
			local v = table[k]
			local tid = TypeID(v)
			if (tid == TYPE_TABLE and i._lastupdate > since)
				or (tid ~= TYPE_TABLE and i > since) then
				count = count + 1
			end
		end

		net.WriteInt(count, 8)
		for k, i in pairs(info) do
			local v = table[k]
			local tid = TypeID(v)
			if tid == TYPE_TABLE then
				if i._lastupdate > since  then
					net.WriteString(k)
					net.WriteInt(tid, 8)
					self:SendTable(v, i, since)
				end
			elseif i > since then
				net.WriteString(k)
				net.WriteInt(tid, 8)
				_typewrite[tid](v)
			end
		end
	end
end

if CLIENT then
	NWTInfo._lastupdate = -1
	NWTInfo._pendingupdate = false
	NWTInfo._received = false

	function NWTInfo:SetValue(value)
		self._value = value
	end

	function NWTInfo:CheckForUpdates()
		if not self._pendingupdate and self._lastupdate
			< self._entity:GetNWFloat(self._key) then
			self._pendingupdate = true

			net.Start("NWTableUpdate")
			net.WriteEntity(self._entity)
			net.WriteString(self._key)
			net.WriteFloat(self._lastupdate)
			net.SendToServer()
		end
	end

	function NWTInfo:ReceiveUpdate(time)
		self._lastupdate = time
		self:ReceiveTable(self._value)
	end

	local _typeread = {
		[TYPE_NIL] = function() end,
		[TYPE_STRING] = function() return net.ReadString() end,
		[TYPE_NUMBER] = function() return net.ReadFloat() end,
		[TYPE_BOOL] = function() return net.ReadBit() == 1 end,
		[TYPE_ENTITY] = function() return net.ReadEntity() end
	}

	function NWTInfo:ReceiveTable(table)
		local count = net.ReadInt(8)
		for i = 1, count do
			local key = net.ReadString()
			local tid = net.ReadInt(8)

			if tid == TYPE_TABLE then
				if not table[key] then table[key] = {} end
				self:ReceiveTable(table[key])
			else
				table[key] = _typeread[tid]()
			end
		end
	end

	net.Receive("NWTableUpdate", function(len, ply)
		local ent = net.ReadEntity()

		if ent and ent:IsValid() and ent._nwts then
			local key = net.ReadString()
			local time = net.ReadFloat()

			local tab = ent._nwts[key]
			if tab then tab:ReceiveUpdate(time) end
			tab._pendingupdate = false
			tab._received = true
		end
	end)
end

function NWTInfo:new(ent, key)
	if self == NWTInfo then
		return setmetatable({}, self):new(ent, key)
	end

	self._entity = ent
	self._key = key

	self._value = {}
	self._info = { _lastupdate = CurTime() }

	return self
end

_mt = FindMetaTable("Entity")

function _mt:SetNetworkedTable(key, value)
	if not self._nwts then self._nwts = {} end

	if not self._nwts[key] then
		self._nwts[key] = NWTInfo:new(self, key)

		if not table.HasValue(_nwtents, self) then
			table.insert(_nwtents, self)
		end
	end

	self._nwts[key]:SetValue(value)
	if SERVER then self:SetNWFloat(key, CurTime()) end
end

function _mt:SetNWTable(key, value)
	self:SetNetworkedTable(key, value)
end

function _mt:GetNetworkedTable(key, default)
	if not self._nwts then self._nwts = {} end

	local tab = self._nwts[key]
	if not tab then
		if CLIENT and self:GetNWFloat(key, -1) ~= -1 then 
			self:SetNetworkedTable(key, {})
		end
		return default
	end

	if CLIENT then tab:CheckForUpdates() end

	if not tab._received then return default end

	return tab._value
end

function _mt:GetNWTable(key, default)
	return self:GetNetworkedTable(key, default)
end
