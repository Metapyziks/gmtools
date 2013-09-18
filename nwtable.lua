-- -- -- -- -- --
-- nwtable.lua --
-- -- -- -- -- --

if SERVER then AddCSLuaFile("nwtable.lua") end

local _nwtents = {}
local _globals = {}

NWTInfo = {}
NWTInfo.__index = NWTInfo

NWTInfo._entity = nil
NWTInfo._key = nil

NWTInfo._keyNums = nil

NWTInfo._value = nil

if SERVER then
    util.AddNetworkString("NWTableUpdate")

    NWTInfo._info = nil
    NWTInfo._nextKeyNum = 1

    function NWTInfo:GetLastUpdateTime()
        return self._info._lastupdate
    end

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
            local kid, vid = TypeID(k), TypeID(v)
            if _typewrite[kid] and (_typewrite[vid] or vid == TYPE_TABLE) then
                if not self._keyNums[k] then
                    self._keyNums[k] = {num = self._nextKeyNum, time = time}
                    self._nextKeyNum = self._nextKeyNum + 1
                end
                if vid == TYPE_TABLE then
                    if not old[k] then
                        old[k] = {}
                        info[k] = {}
                        changed = true
                    end
                    if self:UpdateTable(old[k], info[k], v, time) then
                        changed = true
                    end
                elseif (vid == TYPE_NIL and TypeID(old) ~= TYPE_NIL)
                    or (_typewrite[vid] and old[k] ~= v) then
                    old[k] = v
                    info[k] = time
                    changed = true
                end
            end
        end

        for k, v in pairs(old) do
            if not new[k] and old[k] then
                old[k] = nil
                info[k] = time
                changed = true
            end
        end

        if changed then    info._lastupdate = time end
        return changed
    end

    net.Receive("NWTableUpdate", function(len, ply)
        local ent = net.ReadEntity()
        local key = net.ReadString()
        local time = net.ReadFloat()

        if not ent:IsValid() and _globals[key] then
            _globals[key]:SendUpdate(ply, time)
        elseif ent._nwts and ent._nwts[key] then
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

        local keyBits = 8
        if table.Count(self._keyNums) > 255 then
            keyBits = 16
            if table.Count(self._keyNums) > 65535 then
                keyBits = 32
            end
        end
        net.WriteInt(keyBits, 8)
        for k, v in pairs(self._keyNums) do
            if v.time > since then
                local kid = TypeID(k)
                net.WriteUInt(v.num, keyBits)
                net.WriteInt(kid, 8)
                _typewrite[kid](k)
            end
        end
        net.WriteUInt(0, keyBits)

        self:SendTable(self._value, self._info, since, keyBits)
        net.Send(ply)
    end

    function NWTInfo:SendTable(table, info, since, keyBits)
        local count = 0
        for k, i in pairs(info) do
            if k ~= "_lastupdate" then
                local v = table[k]
                local tid = TypeID(v)
                if (tid == TYPE_TABLE and i._lastupdate and i._lastupdate > since)
                    or (tid ~= TYPE_TABLE and i > since) then
                    count = count + 1
                end
            end
        end

        net.WriteInt(count, 8)
        for k, i in pairs(info) do
            if k ~= "_lastupdate" then
                local v = table[k]
                local tid = TypeID(v)
                if tid == TYPE_TABLE then
                    if i._lastupdate and i._lastupdate > since then
                        net.WriteUInt(self._keyNums[k].num, keyBits)
                        net.WriteInt(tid, 8)
                        self:SendTable(v, i, since, keyBits)
                    end
                elseif i > since then
                    net.WriteUInt(self._keyNums[k].num, keyBits)
                    net.WriteInt(tid, 8)
                    _typewrite[tid](v)
                end
            end
        end
    end
end

if CLIENT then
    NWTInfo._lastupdate = -1
    NWTInfo._pendingupdate = false

    function NWTInfo:SetValue(value)
        self._value = value
    end

    function NWTInfo:NeedsUpdate()
        if self._entity then
            return self._lastupdate < self._entity:GetNWFloat(self._key)
        else
            return self._lastupdate < GetGlobalFloat(self._key)
        end
    end

    function NWTInfo:GetLastUpdateTime()
        return self._lastupdate
    end

    function NWTInfo:CheckForUpdates()
        if not self._pendingupdate and self:NeedsUpdate() then
            self._pendingupdate = true

            net.Start("NWTableUpdate")
            net.WriteEntity(self._entity)
            net.WriteString(self._key)
            net.WriteFloat(self._lastupdate)
            net.SendToServer()
        end
    end

    local _typeread = {
        [TYPE_NIL] = function() end,
        [TYPE_STRING] = function() return net.ReadString() end,
        [TYPE_NUMBER] = function() return net.ReadFloat() end,
        [TYPE_BOOL] = function() return net.ReadBit() == 1 end,
        [TYPE_ENTITY] = function() return net.ReadEntity() end
    }

    function NWTInfo:ReceiveUpdate(time)
        if time < self._lastupdate then return end
        self._lastupdate = time
        local keyBits = net.ReadInt(8)
        while true do
            local num = net.ReadUInt(keyBits)
            if num == 0 then break end
            local kid = net.ReadInt(8)
            self._keyNums[num] = _typeread[kid]()
        end
        self:ReceiveTable(self._value, keyBits)
    end

    function NWTInfo:ReceiveTable(table, keyBits)
        local count = net.ReadInt(8)
        for i = 1, count do
            local key = self._keyNums[net.ReadUInt(keyBits)]
            local tid = net.ReadInt(8)

            if tid == TYPE_TABLE then
                if not table[key] then table[key] = {} end
                self:ReceiveTable(table[key], keyBits)
            else
                table[key] = _typeread[tid]()
            end
        end
    end

    timer.Create("NWTableUpdate", 0, 0, function()
        for _, tbl in pairs(_globals) do
            if tbl then tbl:CheckForUpdates() end
        end
        for _, ent in pairs(_nwtents) do
            if ent._nwts then
                for _, tbl in pairs(ent._nwts) do
                    if tbl then tbl:CheckForUpdates() end
                end
            end
        end
    end)

    net.Receive("NWTableUpdate", function(len, ply)
        local ent = net.ReadEntity()
        local key = net.ReadString()
        local time = net.ReadFloat()

        if not ent:IsValid() then
            local tab = _globals[key]
            if tab then
                tab:ReceiveUpdate(time)
                tab._pendingupdate = false
            end
        elseif ent._nwts then
            local tab = ent._nwts[key]
            if tab then
                tab:ReceiveUpdate(time)
                tab._pendingupdate = false
            end
        end
    end)
end

function NWTInfo:new(ent, key)
    if self == NWTInfo then
        return setmetatable({}, self):new(ent, key)
    end

    self._entity = ent
    self._key = key

    self._keyNums = {}

    self._value = {}

    if SERVER then
        self._info = { _lastupdate = CurTime() }
    end

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

    if value then self._nwts[key]:SetValue(value) end
    if SERVER then self:SetNWFloat(key, self._nwts[key]:GetLastUpdateTime()) end

    return self._nwts[key]._value
end

function _mt:SetNWTable(key, value)
    return self:SetNetworkedTable(key, value)
end

function _mt:GetNetworkedTable(key)
	if not self._nwts then self._nwts = {} end

	local tab = self._nwts[key]
	if not tab then
		if CLIENT and self:GetNWFloat(key, -1) ~= -1 then 
			return self:SetNetworkedTable(key)
		end
		return nil
	end
	return tab._value
end

function _mt:GetNWTable(key)
	return self:GetNetworkedTable(key)
end

function _mt:ForgetNetworkedTable(key)
    if not self._nwts then return end

    if self._nwts[key] then
        self._nwts[key] = nil
        if SERVER then self:SetNWFloat(key, 0) end
    end
end

function _mt:ForgetNWTable(key)
    self:ForgetNetworkedTable(key)
end

function _mt:IsNetworkedTableCurrent(key)
    return self._nwts and self._nwts[key] and (SERVER or not self._nwts[key]:NeedsUpdate())
end

function _mt:IsNWTableCurrent(key)
    return self:IsNetworkedTableCurrent(key)
end

function SetGlobalTable(key, value)
    if not _globals[key] then
        _globals[key] = NWTInfo:new(nil, key)
    end

    if value then _globals[key]:SetValue(value) end
    if SERVER then SetGlobalFloat(key, _globals[key]:GetLastUpdateTime()) end

    return _globals[key]._value
end

function GetGlobalTable(key)
	local tab = _globals[key]
	if not tab then
		--if CLIENT and GetGlobalFloat(key, -1) ~= -1 then
			return SetGlobalTable(key)
		--end
		--return nil
	end
	return tab._value
end

function ForgetGlobalTable(key)
    if _globals[key] then _globals[key] = nil end
end

function IsGlobalTableCurrent(key)
    return _globals[key] and (SERVER or not _globals[key]:NeedsUpdate())
end
